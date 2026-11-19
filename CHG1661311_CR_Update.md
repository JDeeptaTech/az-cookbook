# CHG1661311 – Change Request Field Text

Move Non-Production Subscription 2 to the Tenant Root management group.

Replace everything in angle brackets before pasting into ServiceNow. Do not use "N/A" or "NA" anywhere in the change request.

---

## Short description

```
Move Non-Production Subscription 2 (5cbdde14-4209-49fd-a581-7575a05e988f) to Tenant Root management group
```

---

## Description

```
1. Brief description and business/operational reason
Move Azure subscription "Non-Production Subscription 2" (5cbdde14-4209-49fd-a581-7575a05e988f) from management group "<current management group>" to the Tenant Root Group. This aligns it with the existing subscriptions already placed at root level, so that all subscriptions inherit the same access and policy assignments and are governed consistently:
- Non-Production Subscription (545d0412-2b0f-4af8-bd01-5406431ac144)
- Production Subscription (50fd3e3b-7896-430c-97c0-27aa4984f50a)

2. Impacts during implementation
No impacts to business or operations during implementation. The move is a management-plane change only: no resources are stopped, restarted, redeployed or reconfigured. Role assignments and policy assignments inherited from "<current management group>" stop applying to the subscription and those assigned at Tenant Root Group apply instead; this can take up to 30 minutes to propagate. Inherited role assignments were reviewed before the change and <none are required / the following were recreated at subscription scope: ...>.

3. Worst case scenario and backout plan
Worst case: after the move, users, pipelines or managed identities that relied on access inherited from "<current management group>" lose access to the subscription, or policies inherited from that group stop being enforced. Running non-production workloads continue to run; the impact is limited to management access and deployments for this one non-production subscription. Production is not affected.
Backout: move the subscription back to "<current management group>" via the portal (under 5 minutes, plus up to 30 minutes propagation), which restores the original inherited access and policy.
If the backout fails: raise an incident, engage <Global Administrator / Cloud Platform team> to perform the move using elevated access, and as an interim measure assign the required roles directly at subscription scope.
```

---

## Implementation plan

```
Summary: single manual change in the Azure portal by <implementer> during the approved window. Pre-change state is exported first, then the subscription is moved to the Tenant Root Group. Detailed steps and pre-checks are in attachment "<exact filename, e.g. CHG1661311_Implementation_Plan.docx>" (step-by-step implementation, test and rollback procedure).

Pre-checks
1. Record the current parent management group from the subscription Overview page (screenshot).
2. Download role assignments (Access control (IAM) > Role assignments > Download) including inherited.
3. Export Policy > Assignments and Policy > Compliance at subscription scope.

Implementation
4. Go to Management groups.
5. Find Non-Production Subscription 2 under "<current management group>".
6. Select ... (ellipsis) on the subscription row and choose Move.
7. In New parent management group, select Tenant Root Group.
8. Select Save and wait for the success notification.
9. Refresh and confirm the subscription is listed directly under Tenant Root Group.
10. Allow up to 30 minutes for RBAC and policy inheritance to propagate, then run the test plan.
```

---

## Backout plan

```
Trigger: loss of access for users or pipelines, unexpected policy effect, or any failed test that cannot be fixed within the window.
1. Go to Management groups and find Non-Production Subscription 2 under Tenant Root Group.
2. Select ... > Move, choose "<current management group>", and select Save.
3. Wait up to 30 minutes, then repeat the test plan. Role assignment and policy exports must match the pre-change exports.
4. Remove any subscription-scope role assignments added for this change.
5. Attach the Activity log entry for the move back to the change.
Backout duration: under 5 minutes plus up to 30 minutes propagation.
```

---

## Test plan

```
Pre-production testing: <use option A or B from "Rollback test evidence" below>

Post-implementation tests
1. Placement: the subscription Overview page shows Tenant Root Group as the parent management group.
2. Access: downloaded role assignments are compared with the pre-change export; only the assignments inherited from "<current management group>" are removed.
3. Policy: Policy > Assignments at subscription scope shows only the expected assignments.
4. Functional: <application owner> confirms portal access and <pipeline name> completes a plan/what-if run against the subscription.
5. Evidence: the Activity log entry for the move operation and the before/after screenshots are attached to the change.
```

---

## Before you submit

### Rollback test evidence

The wiki requires evidence of a successful rollback test in a non-production environment. Previous change records are not accepted as evidence. Use one of these in the Test plan:

- **Option A – tested.** Move a sandbox or test subscription to root and back, screenshot both moves and attach them. Test plan wording:

  ```
  Implementation and backout were tested on <subscription> on <date>; evidence in "<filename>".
  ```

  Then tick **Attest - Evidence attached**.

- **Option B – not tested.** State in the Test plan why testing was not possible, select "Back to New" and answer the risk question "Was there any Pre-Production testing performed prior to deployment?" with "Either the Implementation or the Backout was not tested." This may raise the risk above low, which means the change goes to CAB.

### Checks

- [ ] The two other subscriptions listed in the Description are the ones already at root level. If they are also being moved, the short description and all plans must cover all three.
- [ ] The "No impacts" statement is true: the role assignment export shows nothing (users, pipeline service principals, managed identities) depends on access inherited from the current management group.
- [ ] The implementer has Owner on the subscription and write access on the current management group, assigned directly on that group so the backout is still possible after the move.
- [ ] Any attachment is referenced by its exact filename with a brief summary. No "see attached".
- [ ] At least 24 hours between CHG creation time and planned start time.
- [ ] CTASKs are assigned to yourself before updating them.
- [ ] Risk assessment is completed; anything other than low goes to CAB.
- [ ] The correct LOB approver is selected and any others are removed.
- [ ] "N/A" or "NA" does not appear anywhere in the change request.
