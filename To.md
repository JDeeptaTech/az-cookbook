Questions for the Cortex team, grouped by how much they block you. The first group gates the port; the rest can trail.
Template & registration (blocking — ask first)
Where is the VS Code + Cortex template repo, and is my pack layout (agent.yaml, workflow/, rules/, contracts/, tools/, scenarios/, evaluations/) the expected structure or does the template scaffold differ?
What checkpointer does the Cortex runtime provide (Postgres/Redis/managed?), and do I just pass it to graph.compile() or is compilation owned by the runtime?
What exactly does "Register in Cortex" involve — submission process, who reviews, what the Agent Registry validates, lead time?
What are the valid authority levels and their semantics? Is A1 recommend-only as I've assumed, and what's the promotion process?
Tools / MCP (blocking for real adapters)
5. What's the tool naming convention (skyline.get_upgrade_path vs your openshift.get_pod_status style), and how do I register a new MCP capability — can my team publish the Skyline server, or does a central team own the gateway?
6. Is there a dev MCP gateway (your mode 2) I can point at today, and what identity does my dev workstation use?
7. How are write actions marked as approval-gated — in the capability definition, agent.yaml, or policy engine?
Model gateway (needed for the escalate branch only)
8. What's the model_gateway.invoke() client/import, which models are approved, and does output_schema take a pydantic model, a JSON schema, or their own type?
9. Token/timeout budgets per invocation and per agent — where are they set and what happens on breach?
Approval & HITL
10. How do approvers receive Cortex approval requests (ServiceNow, Teams, Cortex UI?), and can the interrupt payload render structured content (my release list)?
11. Approval SLA/expiry — what happens to a checkpoint nobody approves for a week?
Evaluation & operations
12. What does the evaluations/ format need to look like for registry validation — is my scenarios/expected-results pattern compatible, and is there a minimum eval bar to register?
13. Observability: what OTel attributes/conventions must the agent emit, and where do traces land?
14. Versioning: how do agent version upgrades roll out — blue/green, and can a v0.1.0 checkpoint be resumed by v0.2.0?
If you only get one meeting: questions 1, 2, 5, and 8 — those are the four places my implementation guessed at internal conventions, and everything else is refinement. Question 5 is the sleeper again: whether your team can publish MCP capabilities or must file requests with a central gateway team determines your delivery timeline more than any technical factor.
Also worth asking as a closer: "Is there a registered agent in production whose repo I can read?" — one working example answers half this list implicitly, and asking for it signals you'll learn from precedent rather than generate review burden.
