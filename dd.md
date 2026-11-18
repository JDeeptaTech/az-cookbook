Implementation
Go to Management groups.
Expand the hierarchy and find the subscription under its current management group.
Select the … (ellipsis) on the subscription row and choose Move.
In the New parent management group dropdown, select Tenant Root Group (or your top-level group).
Select Save.
Wait for the success notification, then refresh. The subscription should now be listed directly under the target group.
Allow up to 30 minutes for RBAC and policy inheritance to propagate.
Testing
Placement: the subscription’s Overview page shows the new parent management group.
RBAC: download role assignments again and compare with the pre-change export. Only the old inherited entries should be gone.
Policy: in Policy > Assignments, the old management group assignments no longer appear at the subscription scope. Check Policy > Compliance after the next evaluation for unexpected non-compliance. An on-demand scan can only be triggered from the CLI or API; otherwise evaluation runs automatically within about 24 hours.
Functional access: the application owner and pipeline identity confirm they can still reach resources.
Evidence: in Management groups, open the target group’s Activity log, find the move operation and attach it to the change.
Rollback
Go to Management groups and find the subscription under the root group.
Select … > Move, choose the original management group, and select Save.
Wait up to 30 minutes, then repeat the tests. The exports should match the pre-change ones.
Remove any subscription-scope role assignments you added for this change.
