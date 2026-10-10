// Package events reads the parts of a Kubernetes audit event (audit.k8s.io/v1)
// that the sink counts, and maps them to bounded metric labels: who acted
// (the agent, the approval controller, the system, a human), how the API
// server answered, and whether it changed configuration that guards the
// agent (admission, RBAC, network policy, the kill switch).
package events

import (
	"encoding/json"
	"strings"
)

type user struct {
	Username string   `json:"username"`
	Groups   []string `json:"groups"`
}

// Event is the subset of an audit event the sink uses.
type Event struct {
	AuditID          string `json:"auditID"`
	Stage            string `json:"stage"`
	Verb             string `json:"verb"`
	User             user   `json:"user"`
	ImpersonatedUser *user  `json:"impersonatedUser"`
	ObjectRef        *struct {
		Resource    string `json:"resource"`
		Namespace   string `json:"namespace"`
		Name        string `json:"name"`
		APIGroup    string `json:"apiGroup"`
		Subresource string `json:"subresource"`
	} `json:"objectRef"`
	ResponseStatus *struct {
		Code int `json:"code"`
	} `json:"responseStatus"`
}

// The agents' namespace: every identity in it is an agent (P3-01).
const agentGroup = "system:serviceaccounts:agent"
const controllerUser = "system:serviceaccount:approval-system:approval-controller"

// Actors, Outcomes and Changed are every label value Classify returns.
var (
	Actors   = []string{"agent", "approval-controller", "system", "human"}
	Outcomes = []string{"allowed", "forbidden", "unauthorized", "error", "unknown"}
	// Configuration that guards the agent. A change to any of it can widen
	// what the agent may do or remove a check.
	Changed = []string{
		"validatingwebhookconfigurations", "mutatingwebhookconfigurations",
		"validatingadmissionpolicies", "validatingadmissionpolicybindings",
		"mutatingadmissionpolicies", "mutatingadmissionpolicybindings",
		"roles", "rolebindings", "clusterroles", "clusterrolebindings",
		"networkpolicies", "ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies",
		"kill-switch",
	}
	// Changes to these are admission configuration (GAP-02's alert).
	Admission = Changed[:6]
)

var changed = map[string]bool{}

func init() {
	for _, r := range Changed {
		changed[r] = true
	}
}

// Parse reads an event.
func Parse(raw []byte) (Event, error) {
	var e Event
	err := json.Unmarshal(raw, &e)
	return e, err
}

// Final says whether this is the event's last stage, the one to count:
// ResponseStarted precedes ResponseComplete for long-running requests.
func (e Event) Final() bool { return e.Stage == "ResponseComplete" || e.Stage == "Panic" }

// Actor is who acted: the impersonated user if there is one.
func (e Event) Actor() string {
	u := e.User
	if e.ImpersonatedUser != nil {
		u = *e.ImpersonatedUser
	}
	switch {
	case strings.HasPrefix(u.Username, "system:serviceaccount:agent:"):
		return "agent"
	case u.Username == controllerUser:
		return "approval-controller"
	}
	for _, g := range u.Groups {
		if g == agentGroup {
			return "agent"
		}
	}
	if strings.HasPrefix(u.Username, "system:") {
		return "system"
	}
	return "human"
}

// Outcome is how the API server answered.
func (e Event) Outcome() string {
	if e.ResponseStatus == nil || e.ResponseStatus.Code == 0 {
		return "unknown"
	}
	switch c := e.ResponseStatus.Code; {
	case c < 400:
		return "allowed"
	case c == 401:
		return "unauthorized"
	case c == 403:
		return "forbidden"
	default:
		return "error"
	}
}

// Change is the guarded configuration this event changed, or "".
func (e Event) Change() string {
	switch e.Verb {
	case "create", "update", "patch", "delete", "deletecollection":
	default:
		return ""
	}
	if e.ObjectRef == nil || e.Outcome() != "allowed" {
		return ""
	}
	r := e.ObjectRef
	if r.Resource == "configmaps" && r.Namespace == "approval-system" && r.Name == "agent-kill-switch" {
		return "kill-switch"
	}
	if changed[r.Resource] && r.Subresource == "" && r.Resource != "kill-switch" {
		return r.Resource
	}
	return ""
}
