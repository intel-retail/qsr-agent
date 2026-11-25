# QSR deployer

MCP service that lets the agent deploy the store's services to remote Linux nodes. On "deploy all
services" the `service-deployment` skill shows the plan, waits for operator approval, then calls
`deploy_services`. For each service the deployer opens an SSH session (key authentication, pinned
host key), clones or updates the repository on the node, merges the configured variables into the
service's env file, runs the build and start commands, and checks that the service's MCP port
answers.

| Tool | Kind | Purpose |
|---|---|---|
| `describe_deploy_plan` | read | Ordered plan: node, repo, ref, commands, variable names (never values) |
| `deploy_services` | action | Starts a background job (all services, or the named ones); one job at a time |
| `get_deployment_status` | read | Per-service status, exit code, `verified`, redacted log tail |

Deployments are operator-led in chat only. `docker-compose.yaml` removes the three tools from
autonomous event handling (`QSR_AUTONOMY_DISABLED_TOOLS`; setting that variable yourself replaces
the default, so keep the `deployer.*` names in it). The HTTP endpoint requires a bearer token
(`QSR_DEPLOYER_TOKEN`, at least 16 characters; `/health` is open) and is not published on the host.

## Set up

1. Copy the inventory and edit it (nodes, repositories, start commands, per-service `env`):

   ```bash
   cp deployer-config/inventory.example.yaml deployer-config/inventory.yaml
   ```

2. Add private keys under `deployer-config/keys/` (`chmod 600`, owned by the user running
   `make deployer`; the container runs as that user), and reference them from the inventory.
3. Pin each node's host key and verify the fingerprint out of band. Unknown or changed keys are
   rejected.

   ```bash
   ssh-keyscan -H 10.0.0.11 >> deployer-config/known_hosts
   ssh-keygen -lf deployer-config/known_hosts
   ```

   For an SSH port other than 22, scan with `-p <port>` so the entry is stored as `[host]:port`.

4. Start it:

   ```bash
   make deployer
   ```

   This creates the bearer token in `deployer-config/deployer.env` (git-ignored, shared with the agent
   container only), builds and starts the deployer, sets `QSR_DEPLOYER_MCP_URL` and
   `COMPOSE_PROFILES=deployer` in `.env.example` so it survives `make up`, and recreates the agent so it
   registers the service.

5. After the operator deploys services from chat, connect the agent to them:

   ```bash
   make connect-services
   ```

   This writes each deployed service's `agent_env` URLs from the inventory into `.env.example` and
   recreates the agent, which then registers them and loads their skills. Without it a deployed
   service is running but unknown to the agent.

The agent itself is not deployed by this service (it is already running, and redeploying it would
restart the process that holds the deployment session).

Validate an inventory without a container (after `pip install -e services/deployer`):
`QSR_DEPLOYER_INVENTORY=deployer-config/inventory.yaml qsr-deployer check`; print what
`make connect-services` would write with `qsr-deployer agent-env`.

## Behaviour

- Services deploy sequentially in inventory order; a failed service does not stop the rest.
- `verified` only means the `mcp_url` host and port accepted a TCP connection after start; it is not
  an MCP or health check.
- The checkout is `<base_dir>/<service name>` on the node. Local edits to tracked files are
  discarded on redeploy; the inventory is the source of truth. `env` values are merged into
  `<dir>/<env_file>` (created from `<env_file>.example` when missing); `shell_env` is exported for
  git, the build and the start commands only.
- `pre` (optional) runs in the service's existing checkout before git updates it, for example to
  take back files that containers left owned by another user. It is skipped on the first deployment.
- Node requirements: Linux, `git`, `awk`, and whatever the start command needs (usually Docker
  and `make`, with the SSH account in the `docker` group). Repositories must be `https://`.
- Secrets travel on SSH stdin, never on a command line, and are redacted from returned logs.
  The inventory, known_hosts and keys are mounted only into this container, not the agent, and are excluded from image builds
  and from git.
- Job state is in memory: restarting the deployer forgets past jobs.
- A deployment ends when the node script exits, so a start command that backgrounds a process must
  redirect its output (`docker compose up -d` does); otherwise it dies on its first write after the
  SSH session closes. On timeout the deployer kills the script's process group on the node.
- Not included: stop, restart, status of running services, private-repository credentials.

## Tests

```bash
cd services/deployer && pip install -e . && python -m unittest discover -s tests
```

The node-script tests need `bash`, `git` and `awk` and skip otherwise.
