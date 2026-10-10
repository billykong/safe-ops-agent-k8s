package events

import "testing"

func TestClassify(t *testing.T) {
	cases := []struct {
		name, raw              string
		actor, outcome, change string
	}{
		{"agent proposes",
			`{"stage":"ResponseComplete","verb":"create","user":{"username":"system:serviceaccount:agent:proposer","groups":["system:serviceaccounts","system:serviceaccounts:agent"]},"objectRef":{"resource":"changerequests","namespace":"approvals"},"responseStatus":{"code":201}}`,
			"agent", "allowed", ""},
		{"agent refused",
			`{"stage":"ResponseComplete","verb":"delete","user":{"username":"system:serviceaccount:agent:runner"},"objectRef":{"resource":"validatingadmissionpolicies","name":"agent-write-guard"},"responseStatus":{"code":403}}`,
			"agent", "forbidden", ""},
		{"human impersonating the agent counts as the agent",
			`{"stage":"ResponseComplete","verb":"get","user":{"username":"kubernetes-admin","groups":["kubeadm:cluster-admins"]},"impersonatedUser":{"username":"system:serviceaccount:agent:proposer"},"responseStatus":{"code":200}}`,
			"agent", "allowed", ""},
		{"controller",
			`{"stage":"ResponseComplete","verb":"patch","user":{"username":"system:serviceaccount:approval-system:approval-controller"},"objectRef":{"resource":"deployments","namespace":"workloads","name":"web"},"responseStatus":{"code":200}}`,
			"approval-controller", "allowed", ""},
		{"admin removes the guard",
			`{"stage":"ResponseComplete","verb":"delete","user":{"username":"kubernetes-admin"},"objectRef":{"resource":"validatingadmissionpolicybindings","name":"agent-write-guard","apiGroup":"admissionregistration.k8s.io"},"responseStatus":{"code":200}}`,
			"human", "allowed", "validatingadmissionpolicybindings"},
		{"kill switch flipped",
			`{"stage":"ResponseComplete","verb":"patch","user":{"username":"alice"},"objectRef":{"resource":"configmaps","namespace":"approval-system","name":"agent-kill-switch"},"responseStatus":{"code":200}}`,
			"human", "allowed", "kill-switch"},
		{"other configmap",
			`{"stage":"ResponseComplete","verb":"patch","user":{"username":"alice"},"objectRef":{"resource":"configmaps","namespace":"approval-system","name":"approval-policy"},"responseStatus":{"code":200}}`,
			"human", "allowed", ""},
		{"reading RBAC is no change",
			`{"stage":"ResponseComplete","verb":"list","user":{"username":"system:kube-controller-manager"},"objectRef":{"resource":"clusterroles"},"responseStatus":{"code":200}}`,
			"system", "allowed", ""},
		{"a resource named like a label isn't one",
			`{"stage":"ResponseComplete","verb":"create","user":{"username":"alice"},"objectRef":{"resource":"kill-switch"},"responseStatus":{"code":201}}`,
			"human", "allowed", ""},
		{"no status",
			`{"stage":"Panic","verb":"get","user":{"username":"system:anonymous"}}`,
			"system", "unknown", ""},
		{"unauthorized",
			`{"stage":"ResponseComplete","verb":"get","user":{"username":"system:anonymous"},"responseStatus":{"code":401}}`,
			"system", "unauthorized", ""},
	}
	labels := func(vals []string) map[string]bool {
		m := map[string]bool{"": true}
		for _, v := range vals {
			m[v] = true
		}
		return m
	}
	actors, outcomes, changes := labels(Actors), labels(Outcomes), labels(Changed)
	for _, c := range cases {
		e, err := Parse([]byte(c.raw))
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if !e.Final() {
			t.Errorf("%s: not final", c.name)
		}
		if got := e.Actor(); got != c.actor || !actors[got] {
			t.Errorf("%s: actor %q, want %q", c.name, got, c.actor)
		}
		if got := e.Outcome(); got != c.outcome || !outcomes[got] {
			t.Errorf("%s: outcome %q, want %q", c.name, got, c.outcome)
		}
		if got := e.Change(); got != c.change || !changes[got] {
			t.Errorf("%s: change %q, want %q", c.name, got, c.change)
		}
	}
}

func TestResponseStartedIsNotFinal(t *testing.T) {
	e, _ := Parse([]byte(`{"stage":"ResponseStarted","verb":"watch"}`))
	if e.Final() {
		t.Fatal("ResponseStarted counted")
	}
}
