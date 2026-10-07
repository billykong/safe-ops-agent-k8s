# Runbook: stop the agent (kill switch)

Stops the agent completely with one command, and brings it back deliberately. Covers P2-21 and P2-22. Tested end to end by `make test-kill-switch`, which runs every step below against an agent that is mid-task, with a pending proposal and a copy of its token held outside the cluster.

## When to use it

Stop first, investigate second. Use it whenever you're not sure the agent is acting on your behalf:

- it proposes changes nobody asked for, or many in a short time (the change budget filling up is a signal);
- its sandboxes behave like an attack (`make attack-demos` shows what that looks like);
- a prompt injection, a malicious package or a leaked agent token is suspected;
- you are decommissioning it.

Stopping costs little: everything it does is proposed and recorded, and resuming is one command.

## Stop

Needs cluster-admin.

```bash
./scripts/kill-switch.sh stop --reason "what happened, ticket link"
```

It does four things, in this order, and reports the settled state (about 2 s on kind):

| Step | What it does | What it closes |
| --- | --- | --- |
| 1. Flag | Sets ConfigMap `approval-system/agent-kill-switch` to `mode: stop`, with the reason, your username and the time. | Immediately, admission refuses the agent's new sandbox claims and proposals, every new pod in the `agent` namespace, and every new token for it, whoever asks (`agent-kill-switch` policy). The approval controller cancels every ChangeRequest that hasn't started applying, whoever approved it, and the change budget pays for nothing. |
| 2. Scale to zero | Suspends Jobs and CronJobs, scales Deployments and StatefulSets to 0, deletes the remaining pods in `agent`. | The running agent. Its SIGTERM handler still releases its sandbox: deleting its own claims stays allowed while stopped. Nothing can bring a pod back while the flag says stop, even un-suspending the Job (it gets `FailedCreate`). |
| 3. Revoke credentials | Deletes and recreates ServiceAccount `agent/agent`. | Every token ever issued for it, including copies taken out of the cluster. Tokens name the account's UID, which is now different, so the API server refuses them, for reads too. Admission never sees reads; this is what stops them. RoleBindings refer to the account by name, so they apply to the new one. |
| 4. Release sandboxes | Deletes SandboxClaims named `agent-*` in `sandboxes`. | Sandboxes the agent didn't release itself. Their pods go with them. |

An apply already under way (phase `Applying`) is allowed to finish: it's one idempotent patch a human (or the budget) approved, and the controller doesn't start another.

Flipping only the flag (`kubectl edit configmap -n approval-system agent-kill-switch`) is the minimum. It stops all new writes, pods and tokens at once, but a running agent keeps reading until steps 2 and 3 run.

## Check it's stopped

```bash
./scripts/kill-switch.sh status
```

Expect `mode=stop`, zero agent pods, every job `suspend=true`, zero agent claims, zero open requests. `kubectl get changerequests -A` shows the previously open ones as `Cancelled`, with the reason. Note that `kubectl auth can-i ... --as=system:serviceaccount:agent:agent` still says `yes` for proposing: RBAC is unchanged, and the refusal comes from admission. A server-side dry run as the agent shows it (`agent-kill-switch: the agent is stopped (...)`).

## While stopped

- **Forensics.** Pods are gone, but everything the agent did is recorded: ChangeRequests (proposal, pre-state, plan, rollback, who approved, the budget's grants), the agent's logs if collected (P4), and the API audit log. A sandbox's state goes when its claim is released. To keep one, delete the agent's pods but not its claims: run steps 1 to 3 by hand.
- **No debugging pods in `agent`.** Pod creation there is refused for everyone. Debug elsewhere, with a copy of the pod spec.
- **Humans still work.** Approvers can read requests; cluster admins can change workloads directly. Proposals created by humans are cancelled too: the whole proposal pipeline is frozen, not just the agent's part.
- **Don't re-deploy to fix it.** `make p2` creates the flag only if it's missing and never overwrites it, so re-deploying doesn't un-stop the agent.

## Resume (break glass)

Only after the cause is understood, and ideally by someone other than the person who stopped it.

```bash
./scripts/kill-switch.sh resume --reason "root cause, fix, who agreed"
```

It sets `mode: run` and nothing else. The agent's workloads stay suspended, and cancelled proposals stay cancelled. Then, deliberately:

1. Review what the agent proposed before it was stopped (`approvalctl list`, including `Cancelled`), and the change budget's grants (`approvalctl budget`). Lower or delete the budget if autonomy was part of the problem.
2. Restart the agent: re-create its Job (or `kubectl patch job ... -p '{"spec":{"suspend":false}}'`). Its new pods get tokens for the new ServiceAccount.
3. Have the agent re-propose anything still needed. Old proposals don't come back.

## Decommission

Stop as above, then remove the agent's access: delete its RoleBindings (`agent-sandbox-claimer` in `sandboxes`, `agent-changerequest-proposer` in `approvals`), its ServiceAccount and the `agent` namespace. Leave the flag at `stop`, so a re-deployed agent stays stopped until someone resumes it on purpose. The ChangeRequests are the record of what it did; keep them as long as your audit policy requires.

## Failure modes

| Situation | What happens | Do |
| --- | --- | --- |
| The flag ConfigMap is deleted, or `mode` is anything but exactly `run` | Fail closed: stopped. With the flag missing, admission also refuses everyone's sandbox claims and ChangeRequests (the API server applies a missing-parameter denial before evaluating who is asking), and pods and tokens in `agent`. Nothing else in the cluster is affected. | `resume`, which re-creates it. |
| The approval controller is down | Admission still stops the agent (it's evaluated in the API server). Proposals aren't cancelled until the controller is back, and nothing is applied in the meantime either. | Stop works without the controller; restart the controller to settle the record. |
| The controller can't read the flag (RBAC broken, API errors) | It applies nothing and retries: an unreadable flag never means run. | Fix its access (`manifests/20-controller-rbac.yaml`). |
| The `agent-kill-switch` policy or its bindings are deleted | Admission no longer checks the flag. Kubernetes doesn't apply admission policies to admission configuration, so nothing prevents this for someone with RBAC on it ([GAP-02](../known-gaps.md#gap-02-admission-guards-cant-protect-their-own-configuration)). The agent has none, as `make test-kill-switch` and `make test-agent-guard` check. | Re-apply `projects/02-approval-gate/manifests/90-kill-switch.yaml`. Steps 2 and 3 don't depend on it. |
| A token was taken from the agent and the switch wasn't used | Valid until it expires (about an hour for projected tokens). | Step 3 alone: `stop`, or recreate the ServiceAccount. |

## Testing

`make test-kill-switch` runs the whole runbook (stop, check, resume, the fail-closed cases) and leaves the switch at `run`. Run it after any change to the agent's RBAC, the admission policies or the controller, and as part of the eval suite (P4).
