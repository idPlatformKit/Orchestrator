package main

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/crossplane/function-sdk-go/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// Labels the Tenant composition puts on each environment's namespace.
const (
	labelTenant      = "platform.idplatformkit.io/tenant"
	labelEnvironment = "platform.idplatformkit.io/environment"

	// Labels this function puts on what it composes.
	labelApp       = "platform.idplatformkit.io/app"
	labelComponent = "platform.idplatformkit.io/component"

	// The key of the namespace in the required resources.
	requiredNamespace = "namespace"

	// The platform's Gateway, and the domain its wildcard certificate covers.
	gatewayName      = "platform"
	gatewayNamespace = "platform-gateway"
	gatewaySection   = "https"
	// Where Envoy Gateway runs the Gateway's proxy pods: the tenant
	// namespaces only accept traffic from their own pods otherwise.
	gatewayProxyNamespace = "envoy-gateway-system"
	domain                = "127.0.0.1.nip.io"
)

// Function composes an App.
type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer

	log logging.Logger
}

// RunFunction runs the Function.
func (f *Function) RunFunction(_ context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {
	rsp := response.To(req, response.DefaultTTL)

	oxr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get the observed App"))
		return rsp, nil
	}
	ns := oxr.Resource.GetNamespace()

	// The environment comes from the namespace's labels, set by the Tenant
	// composition. Ask Crossplane for the namespace; it calls the function
	// again with it.
	rsp.Requirements = &fnv1.Requirements{Resources: map[string]*fnv1.ResourceSelector{
		requiredNamespace: {ApiVersion: "v1", Kind: "Namespace", Match: &fnv1.ResourceSelector_MatchName{MatchName: ns}},
	}}
	nss, resolved, err := request.GetRequiredResource(req, requiredNamespace)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get the App's namespace"))
		return rsp, nil
	}
	if !resolved {
		return rsp, nil
	}
	if len(nss) != 1 {
		response.Fatal(rsp, errors.Errorf("cannot read the namespace %q", ns))
		return rsp, nil
	}
	labels := nss[0].Resource.GetLabels()
	env := Environment{Name: labels[labelEnvironment], Tenant: labels[labelTenant]}
	if env.Name == "" || env.Tenant == "" {
		response.Fatal(rsp, errors.Errorf("namespace %q isn't a tenant's environment: an App lives in <tenant>-<environment>, created by a Tenant", ns))
		return rsp, nil
	}

	spec := Spec{}
	if err := oxr.Resource.GetValueInto("spec", &spec); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read the App's spec"))
		return rsp, nil
	}

	observed, err := request.GetObservedComposedResources(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get the observed resources"))
		return rsp, nil
	}

	c, err := Compose(oxr.Resource.GetName(), ns, env, spec, observed)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get the desired resources"))
		return rsp, nil
	}
	for name, r := range c.Resources {
		desired[name] = r
	}
	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot set the desired resources"))
		return rsp, nil
	}

	dxr, err := request.GetDesiredCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get the desired App"))
		return rsp, nil
	}
	if err := dxr.Resource.SetValue("status", c.Status); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot set the App's status"))
		return rsp, nil
	}
	if err := response.SetDesiredCompositeResource(rsp, dxr); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot set the desired App"))
		return rsp, nil
	}

	for _, w := range c.Waiting {
		response.Normal(rsp, w)
	}
	return rsp, nil
}

// Environment is where an App runs.
type Environment struct {
	Name   string // staging or prod
	Tenant string
}

// The rules of each environment. Unknown environments get staging's.
func (e Environment) replicas() int64 {
	if e.Name == "prod" {
		return 2
	}
	return 1
}

// Spec is the App's spec: the app's app.yaml, plus the images its CI built.
type Spec struct {
	Images     map[string]string    `json:"images"`
	Services   map[string]Service   `json:"services"`
	Components map[string]Component `json:"components"`
}

// Service is a service an app uses.
type Service struct {
	Type string `json:"type"`
}

// Component is a process of an app.
type Component struct {
	Image     string            `json:"image"`
	Port      int64             `json:"port"`
	Env       map[string]string `json:"env"`
	Expose    *Expose           `json:"expose"`
	Resources Resources         `json:"resources"`
}

// Expose publishes a component on the Gateway.
type Expose struct {
	Protocol string `json:"protocol"`
	Path     string `json:"path"`
}

// Resources of each replica of a component.
type Resources struct {
	CPU         string `json:"cpu"`
	Memory      string `json:"memory"`
	MemoryLimit string `json:"memoryLimit"`
}

// Composed is what an App composes.
type Composed struct {
	Resources map[resource.Name]*resource.DesiredComposed
	Status    map[string]any
	// Why components aren't deployed yet.
	Waiting []string
}

// Compose an App: one platform API per service, and per component a
// Deployment, a Service, and a route on the Gateway when it's exposed.
func Compose(app, ns string, env Environment, spec Spec, observed map[resource.Name]resource.ObservedComposed) (*Composed, error) {
	out := &Composed{Resources: map[resource.Name]*resource.DesiredComposed{}}
	svcStatus := map[string]any{}
	cmpStatus := map[string]any{}

	host := fmt.Sprintf("%s-%s.%s", app, ns, domain)
	if l := len(app) + 1 + len(ns); l > 63 {
		return nil, errors.Errorf("the App's hostname label %s-%s is %d characters long, at most 63: shorten the App's name", app, ns, l)
	}

	// Services.
	servicesReady := map[string]bool{}
	for _, name := range sortedKeys(spec.Services) {
		s := spec.Services[name]
		kind, ok := serviceKinds[s.Type]
		if !ok {
			return nil, errors.Errorf("service %q: unknown type %q", name, s.Type)
		}
		rn := resource.Name("service-" + name)
		obj := kind.compose(app, name, ns)
		ready := conditionTrue(observed, rn, "Ready")
		servicesReady[name] = ready
		add(out, rn, obj, ready)
		svcStatus[name] = map[string]any{"ready": ready, "secret": connSecret(app, name)}
	}

	// Components.
	var routes []routeRule
	for _, name := range sortedKeys(spec.Components) {
		c := spec.Components[name]
		image, ok := spec.Images[c.Image]
		if !ok {
			return nil, errors.Errorf("component %q: image %q isn't in spec.images", name, c.Image)
		}
		envVars, uses, err := resolveEnv(app, c.Env, spec.Services)
		if err != nil {
			return nil, errors.Wrapf(err, "component %q", name)
		}
		if c.Expose != nil && c.Port == 0 {
			return nil, errors.Errorf("component %q: expose needs a port", name)
		}

		// A component starts once the services it uses are ready: their
		// connection Secrets exist then. Once deployed, it stays, even if a
		// service is briefly not ready.
		dn := resource.Name("deployment-" + name)
		_, deployed := observed[dn]
		var missing []string
		for _, s := range uses {
			if !servicesReady[s] {
				missing = append(missing, s)
			}
		}
		if len(missing) > 0 && !deployed {
			out.Waiting = append(out.Waiting, fmt.Sprintf("component %s waits for the services %s", name, strings.Join(missing, ", ")))
			cmpStatus[name] = map[string]any{"ready": false, "replicas": int64(0)}
			continue
		}

		replicas := env.replicas()
		available, ready := deploymentReady(observed, dn, replicas)
		add(out, dn, deployment(app, name, ns, env, image, c, envVars, replicas), ready)
		cmpStatus[name] = map[string]any{"ready": ready, "replicas": available}

		if c.Port != 0 {
			sn := resource.Name("service-" + name + "-svc")
			_, exists := observed[sn]
			add(out, sn, kubeService(app, name, ns, c.Port), exists)
		}
		if c.Expose != nil {
			routes = append(routes, routeRule{component: name, path: c.Expose.Path, port: c.Port})
			nn := resource.Name("networkpolicy-" + name)
			_, exists := observed[nn]
			add(out, nn, gatewayIngress(app, name, ns, c.Port), exists)
		}
		if replicas > 1 {
			pn := resource.Name("pdb-" + name)
			_, exists := observed[pn]
			add(out, pn, pdb(app, name, ns), exists)
		}
	}

	status := map[string]any{"environment": env.Name, "services": svcStatus, "components": cmpStatus}
	if len(routes) > 0 {
		rn := resource.Name("route")
		add(out, rn, httpRoute(app, ns, host, routes), routeAccepted(observed, rn))
		status["url"] = "https://" + host
	}
	out.Status = status
	return out, nil
}

func add(out *Composed, name resource.Name, obj map[string]any, ready bool) {
	cd := composed.New()
	cd.SetUnstructuredContent(obj)
	r := resource.ReadyFalse
	if ready {
		r = resource.ReadyTrue
	}
	out.Resources[name] = &resource.DesiredComposed{Resource: cd, Ready: r}
}

// serviceKind is a type of service: the platform API that provides it, and
// its outputs.
type serviceKind struct {
	compose func(app, name, ns string) map[string]any
	// Outputs read from the connection Secret: output name → Secret key.
	keys map[string]string
	// Outputs built from the others: output name → template on them.
	derived map[string]string
}

var serviceKinds = map[string]serviceKind{
	"postgres": {
		compose: func(app, name, ns string) map[string]any {
			return map[string]any{
				"apiVersion": "database.idplatformkit.io/v1alpha1",
				"kind":       "PostgresDatabase",
				"metadata":   meta(app+"-"+name, ns, app, ""),
				"spec": map[string]any{
					"writeConnectionSecretToRef": map[string]any{"name": connSecret(app, name)},
				},
			}
		},
		keys: map[string]string{
			"host": "host", "port": "port", "database": "dbname",
			"username": "username", "password": "password",
		},
		// provider-sql generates alphanumeric passwords, and usernames and
		// database names are <namespace>_<name>: safe in a URL as they are.
		derived: map[string]string{
			"url":     "postgres://${username}:${password}@${host}:${port}/${database}",
			"jdbcUrl": "jdbc:postgresql://${host}:${port}/${database}",
		},
	},
}

func connSecret(app, service string) string { return app + "-" + service + "-conn" }

var (
	reference = regexp.MustCompile(`\$\{([^}]*)\}`)
	output    = regexp.MustCompile(`\$\{([A-Za-z]+)\}`)
	notEnvVar = regexp.MustCompile(`[^A-Z0-9_]`)
)

// resolveEnv turns a component's env into container env vars. A value that
// is exactly one service output becomes a secretKeyRef. A value that mixes
// outputs, or uses a derived one (url), reads each output into a helper
// variable, IDPK_<SERVICE>_<OUTPUT>, and refers to it with Kubernetes'
// $(VAR) expansion. It returns the env vars and the services used.
func resolveEnv(app string, env map[string]string, services map[string]Service) ([]any, []string, error) {
	var helpers, vars []any
	helperSeen := map[string]bool{}
	used := map[string]bool{}

	for _, name := range sortedKeys(env) {
		value := env[name]
		// Kubernetes expands $(VAR) in values: escape what the app wrote.
		escaped := strings.ReplaceAll(value, "$(", "$$(")

		var refErr error
		type ref struct{ service, key string }
		var refs []ref
		expanded := reference.ReplaceAllStringFunc(escaped, func(m string) string {
			path := strings.Split(reference.FindStringSubmatch(m)[1], ".")
			if len(path) != 3 || path[0] != "services" {
				refErr = errors.Errorf("env %s: %s isn't a reference to a service output, ${services.<name>.<output>}", name, m)
				return m
			}
			s, ok := services[path[1]]
			if !ok {
				refErr = errors.Errorf("env %s: %s refers to service %q, which isn't in services", name, m, path[1])
				return m
			}
			kind := serviceKinds[s.Type]
			used[path[1]] = true
			if tpl, ok := kind.derived[path[2]]; ok {
				return output.ReplaceAllStringFunc(tpl, func(o string) string {
					k := kind.keys[output.FindStringSubmatch(o)[1]]
					refs = append(refs, ref{path[1], k})
					return "$(" + helperName(path[1], k) + ")"
				})
			}
			k, ok := kind.keys[path[2]]
			if !ok {
				refErr = errors.Errorf("env %s: %s: a %s service has no output %q (outputs: %s)", name, m, s.Type, path[2], strings.Join(outputs(kind), ", "))
				return m
			}
			refs = append(refs, ref{path[1], k})
			return "$(" + helperName(path[1], k) + ")"
		})
		if refErr != nil {
			return nil, nil, refErr
		}

		// Exactly one plain output: read it directly.
		if len(refs) == 1 && expanded == "$("+helperName(refs[0].service, refs[0].key)+")" {
			vars = append(vars, secretEnv(name, connSecret(app, refs[0].service), refs[0].key))
			continue
		}
		for _, r := range refs {
			h := helperName(r.service, r.key)
			if !helperSeen[h] {
				helperSeen[h] = true
				helpers = append(helpers, secretEnv(h, connSecret(app, r.service), r.key))
			}
		}
		vars = append(vars, map[string]any{"name": name, "value": expanded})
	}

	// Helpers come first: $(VAR) only expands variables defined before.
	sort.Slice(helpers, func(i, j int) bool {
		return helpers[i].(map[string]any)["name"].(string) < helpers[j].(map[string]any)["name"].(string)
	})
	return append(helpers, vars...), sortedKeys(used), nil
}

func helperName(service, key string) string {
	return "IDPK_" + notEnvVar.ReplaceAllString(strings.ToUpper(service+"_"+key), "_")
}

func secretEnv(name, secret, key string) map[string]any {
	return map[string]any{
		"name": name,
		"valueFrom": map[string]any{
			"secretKeyRef": map[string]any{"name": secret, "key": key},
		},
	}
}

func outputs(k serviceKind) []string {
	var o []string
	for n := range k.keys {
		o = append(o, n)
	}
	for n := range k.derived {
		o = append(o, n)
	}
	sort.Strings(o)
	return o
}

func meta(name, ns, app, component string) map[string]any {
	labels := map[string]any{
		"app.kubernetes.io/name":       app,
		"app.kubernetes.io/managed-by": "crossplane",
		labelApp:                       app,
	}
	if component != "" {
		labels["app.kubernetes.io/component"] = component
		labels[labelComponent] = component
	}
	return map[string]any{"name": name, "namespace": ns, "labels": labels}
}

func selector(app, component string) map[string]any {
	return map[string]any{labelApp: app, labelComponent: component}
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

func deployment(app, name, ns string, env Environment, image string, c Component, envVars []any, replicas int64) map[string]any {
	container := map[string]any{
		"name":  name,
		"image": image,
		"resources": map[string]any{
			"requests": map[string]any{"cpu": orDefault(c.Resources.CPU, "50m"), "memory": orDefault(c.Resources.Memory, "64Mi")},
			"limits":   map[string]any{"memory": orDefault(c.Resources.MemoryLimit, "256Mi")},
		},
		// Pod Security restricted, which prod enforces: the same in every
		// environment, so that what runs in staging runs in prod.
		"securityContext": map[string]any{
			"allowPrivilegeEscalation": false,
			"capabilities":             map[string]any{"drop": []any{"ALL"}},
			"runAsNonRoot":             true,
			"seccompProfile":           map[string]any{"type": "RuntimeDefault"},
		},
	}
	if len(envVars) > 0 {
		container["env"] = envVars
	}
	if c.Port != 0 {
		container["ports"] = []any{map[string]any{"name": "http", "containerPort": c.Port}}
		container["readinessProbe"] = map[string]any{"httpGet": map[string]any{"path": "/readyz", "port": "http"}}
		container["livenessProbe"] = map[string]any{"httpGet": map[string]any{"path": "/healthz", "port": "http"}}
	}
	return map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata":   meta(app+"-"+name, ns, app, name),
		"spec": map[string]any{
			"replicas": replicas,
			"selector": map[string]any{"matchLabels": selector(app, name)},
			"template": map[string]any{
				"metadata": map[string]any{"labels": meta("", "", app, name)["labels"]},
				"spec": map[string]any{
					"containers":                   []any{container},
					"automountServiceAccountToken": false,
				},
			},
		},
	}
}

func kubeService(app, name, ns string, port int64) map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "Service",
		"metadata":   meta(app+"-"+name, ns, app, name),
		"spec": map[string]any{
			"selector": selector(app, name),
			"ports":    []any{map[string]any{"name": "http", "port": port, "targetPort": "http"}},
		},
	}
}

func pdb(app, name, ns string) map[string]any {
	return map[string]any{
		"apiVersion": "policy/v1",
		"kind":       "PodDisruptionBudget",
		"metadata":   meta(app+"-"+name, ns, app, name),
		"spec": map[string]any{
			"maxUnavailable": int64(1),
			"selector":       map[string]any{"matchLabels": selector(app, name)},
		},
	}
}

// gatewayIngress lets the Gateway's proxy reach an exposed component, on its
// port only.
func gatewayIngress(app, name, ns string, port int64) map[string]any {
	return map[string]any{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata":   meta(app+"-"+name+"-from-gateway", ns, app, name),
		"spec": map[string]any{
			"podSelector": map[string]any{"matchLabels": selector(app, name)},
			"policyTypes": []any{"Ingress"},
			"ingress": []any{map[string]any{
				"from": []any{map[string]any{"namespaceSelector": map[string]any{
					"matchLabels": map[string]any{"kubernetes.io/metadata.name": gatewayProxyNamespace},
				}}},
				"ports": []any{map[string]any{"port": port}},
			}},
		},
	}
}

type routeRule struct {
	component string
	path      string
	port      int64
}

func httpRoute(app, ns, host string, rules []routeRule) map[string]any {
	// The longest path first, so /api isn't shadowed by /. The Gateway sorts
	// them anyway; this keeps the output stable.
	sort.SliceStable(rules, func(i, j int) bool { return len(rules[i].path) > len(rules[j].path) })
	var rs []any
	for _, r := range rules {
		rs = append(rs, map[string]any{
			"matches":     []any{map[string]any{"path": map[string]any{"type": "PathPrefix", "value": orDefault(r.path, "/")}}},
			"backendRefs": []any{map[string]any{"name": app + "-" + r.component, "port": r.port}},
		})
	}
	return map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1",
		"kind":       "HTTPRoute",
		"metadata":   meta(app, ns, app, ""),
		"spec": map[string]any{
			"parentRefs": []any{map[string]any{"name": gatewayName, "namespace": gatewayNamespace, "sectionName": gatewaySection}},
			"hostnames":  []any{host},
			"rules":      rs,
		},
	}
}

// Readiness of observed resources.

func conditionTrue(observed map[resource.Name]resource.ObservedComposed, name resource.Name, condition string) bool {
	o, ok := observed[name]
	if !ok {
		return false
	}
	conds, _, _ := unstructured.NestedSlice(o.Resource.Object, "status", "conditions")
	return hasTrue(conds, condition)
}

func hasTrue(conds []any, condition string) bool {
	for _, c := range conds {
		m, ok := c.(map[string]any)
		if ok && m["type"] == condition && m["status"] == "True" {
			return true
		}
	}
	return false
}

func deploymentReady(observed map[resource.Name]resource.ObservedComposed, name resource.Name, replicas int64) (int64, bool) {
	o, ok := observed[name]
	if !ok {
		return 0, false
	}
	obj := o.Resource.Object
	gen, _, _ := unstructured.NestedInt64(obj, "metadata", "generation")
	seen, _, _ := unstructured.NestedInt64(obj, "status", "observedGeneration")
	updated, _, _ := unstructured.NestedInt64(obj, "status", "updatedReplicas")
	available, _, _ := unstructured.NestedInt64(obj, "status", "availableReplicas")
	return available, seen >= gen && updated >= replicas && available >= replicas
}

func routeAccepted(observed map[resource.Name]resource.ObservedComposed, name resource.Name) bool {
	o, ok := observed[name]
	if !ok {
		return false
	}
	parents, _, _ := unstructured.NestedSlice(o.Resource.Object, "status", "parents")
	for _, p := range parents {
		m, ok := p.(map[string]any)
		if !ok {
			continue
		}
		if conds, _ := m["conditions"].([]any); hasTrue(conds, "Accepted") {
			return true
		}
	}
	return false
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
