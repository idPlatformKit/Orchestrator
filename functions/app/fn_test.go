package main

import (
	"context"
	"sort"
	"strings"
	"testing"

	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/google/go-cmp/cmp"
	"github.com/google/go-cmp/cmp/cmpopts"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

const app = `{
	"apiVersion": "platform.idplatformkit.io/v1alpha1",
	"kind": "App",
	"metadata": {"name": "hello", "namespace": "shop-staging"},
	"spec": {
		"images": {"web": "registry.example/web@sha256:abc"},
		"services": {"db": {"type": "postgres"}},
		"components": {"web": {"image": "web", "port": 8080, "expose": {"path": "/"},
			"env": {"DATABASE_URL": "${services.db.url}"}}}
	}
}`

func namespace(name string, labels map[string]string) *fnv1.Resources {
	l := map[string]any{}
	for k, v := range labels {
		l[k] = v
	}
	u := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Namespace",
		"metadata": map[string]any{"name": name, "labels": l},
	}}
	s, err := resource.AsStruct(u)
	if err != nil {
		panic(err)
	}
	return &fnv1.Resources{Items: []*fnv1.Resource{{Resource: s}}}
}

func newRequest(t *testing.T, ns *fnv1.Resources) *fnv1.RunFunctionRequest {
	t.Helper()
	xr := &unstructured.Unstructured{}
	if err := xr.UnmarshalJSON([]byte(app)); err != nil {
		t.Fatal(err)
	}
	s, err := resource.AsStruct(xr)
	if err != nil {
		t.Fatal(err)
	}
	req := &fnv1.RunFunctionRequest{
		Observed: &fnv1.State{Composite: &fnv1.Resource{Resource: s}},
		Desired:  &fnv1.State{},
	}
	if ns != nil {
		req.RequiredResources = map[string]*fnv1.Resources{requiredNamespace: ns}
	}
	return req
}

func TestRunFunction(t *testing.T) {
	tenantNs := namespace("shop-staging", map[string]string{labelTenant: "shop", labelEnvironment: "staging"})

	cases := map[string]struct {
		ns            *fnv1.Resources
		wantResources []string
		wantFatal     string
	}{
		"AsksForTheNamespaceFirst": {
			ns:            nil,
			wantResources: nil,
		},
		"RefusesANamespaceThatIsNotATenantEnvironment": {
			ns:        namespace("shop-staging", nil),
			wantFatal: "isn't a tenant's environment",
		},
		"ComposesTheServicesFirst": {
			ns:            tenantNs,
			wantResources: []string{"postgres-db"},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			f := &Function{log: logging.NewNopLogger()}
			rsp, err := f.RunFunction(context.Background(), newRequest(t, tc.ns))
			if err != nil {
				t.Fatal(err)
			}
			if got := rsp.GetRequirements().GetResources()[requiredNamespace].GetMatchName(); got != "shop-staging" {
				t.Errorf("required namespace: got %q", got)
			}
			var fatal string
			for _, r := range rsp.GetResults() {
				if r.GetSeverity() == fnv1.Severity_SEVERITY_FATAL {
					fatal = r.GetMessage()
				}
			}
			if tc.wantFatal == "" && fatal != "" || !strings.Contains(fatal, tc.wantFatal) {
				t.Fatalf("fatal: got %q, want %q", fatal, tc.wantFatal)
			}
			var got []string
			for n := range rsp.GetDesired().GetResources() {
				got = append(got, n)
			}
			if diff := cmp.Diff(tc.wantResources, got, cmpopts.EquateEmpty()); diff != "" {
				t.Errorf("desired resources (-want +got):\n%s", diff)
			}
		})
	}
}

func spec() Spec {
	return Spec{
		Images:   map[string]string{"api": "registry.example/api@sha256:abc"},
		Services: map[string]Service{"db": {Type: "postgres"}},
		Components: map[string]Component{
			"api":    {Image: "api", Port: 8080, Expose: &Expose{Path: "/api"}, Env: map[string]string{"DB_HOST": "${services.db.host}"}},
			"worker": {Image: "api"},
		},
	}
}

func observed(objs map[resource.Name]map[string]any) map[resource.Name]resource.ObservedComposed {
	out := map[resource.Name]resource.ObservedComposed{}
	for n, o := range objs {
		cd := composed.New()
		cd.SetUnstructuredContent(o)
		out[n] = resource.ObservedComposed{Resource: cd}
	}
	return out
}

func readyDB() map[resource.Name]map[string]any {
	return map[resource.Name]map[string]any{
		"postgres-db": {"status": map[string]any{"conditions": []any{map[string]any{"type": "Ready", "status": "True"}}}},
	}
}

func names(c *Composed) []string {
	n := make([]string, 0, len(c.Resources))
	for k := range c.Resources {
		n = append(n, string(k))
	}
	sort.Strings(n)
	return n
}

func TestCompose(t *testing.T) {
	staging := Environment{Name: "staging", Tenant: "shop"}
	prod := Environment{Name: "prod", Tenant: "shop"}

	t.Run("ComponentsWaitForTheirServices", func(t *testing.T) {
		c, err := Compose("orders", "shop-staging", staging, spec(), Confirmed{}, nil)
		if err != nil {
			t.Fatal(err)
		}
		// The worker uses no service: it doesn't wait.
		want := []string{"deployment-worker", "postgres-db"}
		if diff := cmp.Diff(want, names(c)); diff != "" {
			t.Errorf("(-want +got):\n%s", diff)
		}
		if len(c.Waiting) != 1 || !strings.Contains(c.Waiting[0], "api waits for the services db") {
			t.Errorf("waiting: %v", c.Waiting)
		}
	})

	t.Run("ADeployedComponentStaysWhenItsServiceIsNotReady", func(t *testing.T) {
		c, err := Compose("orders", "shop-staging", staging, spec(), Confirmed{}, observed(map[resource.Name]map[string]any{"deployment-api": {}}))
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := c.Resources["deployment-api"]; !ok {
			t.Error("deployment-api was removed")
		}
	})

	t.Run("Staging", func(t *testing.T) {
		c, err := Compose("orders", "shop-staging", staging, spec(), Confirmed{}, observed(readyDB()))
		if err != nil {
			t.Fatal(err)
		}
		want := []string{"deployment-api", "deployment-worker", "networkpolicy-api", "postgres-db", "route", "service-api"}
		if diff := cmp.Diff(want, names(c)); diff != "" {
			t.Errorf("(-want +got):\n%s", diff)
		}
		replicas, _, _ := unstructured.NestedInt64(c.Resources["deployment-api"].Resource.Object, "spec", "replicas")
		if replicas != 1 {
			t.Errorf("replicas: got %d, want 1", replicas)
		}
		if c.Status["url"] != "https://orders-shop-staging.127.0.0.1.nip.io" {
			t.Errorf("url: got %v", c.Status["url"])
		}
		if c.Resources["postgres-db"].Ready != resource.ReadyTrue {
			t.Error("postgres-db should be ready")
		}
		if c.Resources["deployment-api"].Ready != resource.ReadyFalse {
			t.Error("deployment-api isn't observed: it can't be ready")
		}
	})

	t.Run("ProdRunsTwoReplicasWithADisruptionBudget", func(t *testing.T) {
		c, err := Compose("orders", "shop-prod", prod, spec(), Confirmed{}, observed(readyDB()))
		if err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"api", "worker"} {
			replicas, _, _ := unstructured.NestedInt64(c.Resources[resource.Name("deployment-"+name)].Resource.Object, "spec", "replicas")
			if replicas != 2 {
				t.Errorf("%s replicas: got %d, want 2", name, replicas)
			}
			if _, ok := c.Resources[resource.Name("pdb-"+name)]; !ok {
				t.Errorf("no PodDisruptionBudget for %s", name)
			}
		}
	})

	t.Run("ADeploymentIsReadyWhenAllItsReplicasAreAvailable", func(t *testing.T) {
		o := readyDB()
		o["deployment-api"] = map[string]any{
			// Numbers reach the function as float64, from protobuf Structs.
			"metadata": map[string]any{"generation": float64(2)},
			"status":   map[string]any{"observedGeneration": float64(2), "updatedReplicas": float64(1), "availableReplicas": float64(1)},
		}
		c, err := Compose("orders", "shop-staging", staging, spec(), Confirmed{}, observed(o))
		if err != nil {
			t.Fatal(err)
		}
		if c.Resources["deployment-api"].Ready != resource.ReadyTrue {
			t.Error("deployment-api should be ready")
		}
	})

	errs := map[string]struct {
		mutate func(*Spec)
		app    string
		want   string
	}{
		"UnknownImage": {
			mutate: func(s *Spec) { s.Components["worker"] = Component{Image: "nope"} },
			want:   `image "nope" isn't in spec.images`,
		},
		"ExposeWithoutPort": {
			mutate: func(s *Spec) { s.Components["worker"] = Component{Image: "api", Expose: &Expose{Path: "/"}} },
			want:   "expose needs a port",
		},
		"UnknownServiceType": {
			mutate: func(s *Spec) { s.Services["cache"] = Service{Type: "memcached"} },
			want:   `unknown type "memcached"`,
		},
		"HostnameTooLong": {
			app:  strings.Repeat("a", 60),
			want: "at most 63",
		},
	}
	for name, tc := range errs {
		t.Run(name, func(t *testing.T) {
			s := spec()
			if tc.mutate != nil {
				tc.mutate(&s)
			}
			a := tc.app
			if a == "" {
				a = "orders"
			}
			_, err := Compose(a, "shop-staging", staging, s, Confirmed{}, observed(readyDB()))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("got %v, want an error containing %q", err, tc.want)
			}
		})
	}
}

func TestResolveEnv(t *testing.T) {
	services := map[string]Service{"db": {Type: "postgres"}, "orders-db": {Type: "postgres"}}
	secret := func(name, s, key string) any {
		return map[string]any{"name": name, "valueFrom": map[string]any{"secretKeyRef": map[string]any{"name": s, "key": key}}}
	}
	value := func(name, v string) any { return map[string]any{"name": name, "value": v} }

	cases := map[string]struct {
		env      map[string]string
		want     []any
		wantUses []string
		wantErr  string
	}{
		"PlainValue": {
			env:  map[string]string{"MODE": "fast"},
			want: []any{value("MODE", "fast")},
		},
		"OneOutputIsReadFromTheSecret": {
			env:      map[string]string{"PGHOST": "${services.db.host}", "PGDATABASE": "${services.db.database}"},
			want:     []any{secret("PGDATABASE", "app-db-conn", "dbname"), secret("PGHOST", "app-db-conn", "host")},
			wantUses: []string{"db"},
		},
		"ADerivedOutputUsesHelperVariables": {
			env: map[string]string{"JDBC": "${services.db.jdbcUrl}"},
			want: []any{
				secret("IDPK_DB_DBNAME", "app-db-conn", "dbname"),
				secret("IDPK_DB_HOST", "app-db-conn", "host"),
				secret("IDPK_DB_PORT", "app-db-conn", "port"),
				value("JDBC", "jdbc:postgresql://$(IDPK_DB_HOST):$(IDPK_DB_PORT)/$(IDPK_DB_DBNAME)"),
			},
			wantUses: []string{"db"},
		},
		"MixedTextAndServiceNamesWithDashes": {
			env: map[string]string{"ADDR": "tcp://${services.orders-db.host}:${services.orders-db.port}"},
			want: []any{
				secret("IDPK_ORDERS_DB_HOST", "app-orders-db-conn", "host"),
				secret("IDPK_ORDERS_DB_PORT", "app-orders-db-conn", "port"),
				value("ADDR", "tcp://$(IDPK_ORDERS_DB_HOST):$(IDPK_ORDERS_DB_PORT)"),
			},
			wantUses: []string{"orders-db"},
		},
		"KubernetesExpansionIsEscaped": {
			env:  map[string]string{"CMD": "echo $(HOME)"},
			want: []any{value("CMD", "echo $$(HOME)")},
		},
		"UnknownService": {
			env:     map[string]string{"X": "${services.cache.host}"},
			wantErr: `refers to service "cache", which isn't in services`,
		},
		"UnknownOutput": {
			env:     map[string]string{"X": "${services.db.dsn}"},
			wantErr: `no output "dsn" (outputs: database, host, jdbcUrl, password, port, url, username)`,
		},
		"NotAServiceReference": {
			env:     map[string]string{"X": "${HOME}"},
			wantErr: "isn't a reference to a service output",
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			got, uses, err := resolveEnv("app", tc.env, services)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("got %v, want an error containing %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if diff := cmp.Diff(tc.want, got); diff != "" {
				t.Errorf("env (-want +got):\n%s", diff)
			}
			if diff := cmp.Diff(tc.wantUses, uses, cmpopts.EquateEmpty()); diff != "" {
				t.Errorf("uses (-want +got):\n%s", diff)
			}
		})
	}
}

func TestRetainedServices(t *testing.T) {
	staging := Environment{Name: "staging", Tenant: "shop"}
	// The App had a database, cache-db, that isn't in its spec any more.
	o := readyDB()
	o["postgres-cache-db"] = map[string]any{"status": map[string]any{"conditions": []any{map[string]any{"type": "Ready", "status": "True"}}}}

	t.Run("ARemovedServiceIsKept", func(t *testing.T) {
		c, err := Compose("orders", "shop-staging", staging, spec(), Confirmed{}, observed(o))
		if err != nil {
			t.Fatal(err)
		}
		r, ok := c.Resources["postgres-cache-db"]
		if !ok {
			t.Fatal("postgres-cache-db was removed: its database would be dropped")
		}
		if name := r.Resource.GetName(); name != "orders-cache-db" {
			t.Errorf("recomposed as %q, want orders-cache-db", name)
		}
		want := map[string]any{"cache-db": map[string]any{"type": "postgres", "ready": true, "secret": "orders-cache-db-conn"}}
		if diff := cmp.Diff(want, c.Status["retainedServices"]); diff != "" {
			t.Errorf("retainedServices (-want +got):\n%s", diff)
		}
		if len(c.Warnings) != 1 || !strings.Contains(c.Warnings[0], "add cache-db to the annotation platform.idplatformkit.io/delete-services") {
			t.Errorf("warnings: %v", c.Warnings)
		}
	})

	t.Run("AConfirmedServiceIsDeleted", func(t *testing.T) {
		for _, a := range []string{"cache-db", " other , cache-db ", "*"} {
			c, err := Compose("orders", "shop-staging", staging, spec(), ParseDeleteServices(a), observed(o))
			if err != nil {
				t.Fatal(err)
			}
			if _, ok := c.Resources["postgres-cache-db"]; ok {
				t.Errorf("annotation %q: postgres-cache-db is still composed", a)
			}
			if _, ok := c.Status["retainedServices"]; ok {
				t.Errorf("annotation %q: retainedServices is still set", a)
			}
		}
	})

	t.Run("ConfirmingDoesNotDeleteAServiceStillInTheSpec", func(t *testing.T) {
		c, err := Compose("orders", "shop-staging", staging, spec(), ParseDeleteServices("*"), observed(o))
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := c.Resources["postgres-db"]; !ok {
			t.Error("postgres-db is in the spec: it must stay")
		}
	})
}
