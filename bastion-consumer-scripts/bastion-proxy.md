# Bastion Proxy — private access without a VPN

Need to reach a database, cache, or AI endpoint that only lives inside the
private network? Normally that means standing up a VPN or RDP'ing into a jump
server. This skips all of that.

Run one command. It opens a secure tunnel through **Azure Bastion** to the
jumpbox VM, and gives you a local **SOCKS5 proxy** at `localhost:8228`. Point
any tool at that proxy and your traffic comes out the other side — inside the
private network, resolved and routed by the jumpbox.

One proxy port reaches **anything the jumpbox can reach**: Cosmos DB,
PostgreSQL, Redis, Azure OpenAI, AI Search, and more. No per-service setup, no
VPN client, no fiddling.

There are two scripts that do exactly the same thing — pick the one that
matches your machine:

| Script | Use it on |
|--------|-----------|
| `bastion-proxy.ps1` | Windows (PowerShell) |
| `bastion-proxy.sh`  | macOS, Linux, or Git Bash on Windows |

---

## Before you start

You'll need three things. The good news: the script handles most of the setup
for you.

**Handled automatically** — the script installs these the first time if they're
missing:

- The **Azure CLI**
- The Azure CLI **`bastion`** and **`ssh`** extensions

**You need to have** — these are set up once by whoever owns the environment:

- A **Standard SKU Azure Bastion** with native tunnelling turned on
- The **"Virtual Machine Administrator Login"** role on the jumpbox VM, assigned
  to you (or a group you're in)

That last one matters: signing in to Azure isn't enough on its own. You also
have to be granted login rights on the VM itself. If the tunnel connects but
then drops, this is the usual reason — ask your environment owner to confirm
your role assignment.

---

## How to run it

You'll need three names for your environment — the **resource group**, the
**Bastion host**, and the **jumpbox VM**. Your environment owner can give you
these, or you can read them from your Terraform outputs.

### Windows (PowerShell)

```powershell
.\scripts\bastion-proxy.ps1 -ResourceGroup <resource-group> -BastionName <bastion-name> -VmName <vm-name>
```

### macOS / Linux / Git Bash

```bash
./scripts/bastion-proxy.sh -g <resource-group> -b <bastion-name> -v <vm-name>
```

That's it. The first run takes a minute while it sets things up and pops open a
browser for sign-in. After that, it's fast.

### A real example

For this repo's deployment:

```bash
./scripts/bastion-proxy.sh \
  -g eo-dmi-alz-bastion-jumpbox-tools \
  -b eo-dmi-alz-bastion-jumpbox-bastion \
  -v eo-dmi-alz-bastion-jumpbox-jumpbox
```

### Options

| Short | Long | What it does | Default |
|-------|------|--------------|---------|
| `-g` | `-ResourceGroup` / `--resource-group` | Resource group holding the Bastion and VM | **required** |
| `-b` | `-BastionName` / `--bastion-name` | Name of the Bastion host | **required** |
| `-v` | `-VmName` / `--vm-name` | Name of the jumpbox VM | **required** |
| `-s` | `-SubscriptionId` / `--subscription` | Azure subscription to use | the repo default |
| `-p` | `-Port` / `--port` | Starting local port for the proxy | `8228` |

---

## What happens when you run it

The script walks through a few checks and tells you where it is at every step,
so you're never left guessing:

1. **Sets up the tools** — installs the Azure CLI and extensions if they're not
   already there.
2. **Signs you in** — opens a browser for Entra sign-in with MFA, in the BC Gov
   tenant. If you're already signed in, it just confirms and moves on.
3. **Checks the VM** — if the jumpbox is stopped, it offers to start it for you.
   Just answer `y`.
4. **Checks Bastion** — makes sure the Bastion host is healthy and ready. If
   it's mid-provisioning, the script waits for it.
5. **Picks a port** — uses `8228`, or the next free one if that's taken, and
   tells you which.
6. **Opens the tunnel** — and prints your connection details.
7. **Launches a browser** — if you have Edge or Chrome, it opens a fresh window
   already pointed at the proxy, ready to browse private sites.

When it's ready, you'll see something like this:

```
  Preparing SOCKS5 proxy on localhost:8228

  export HTTPS_PROXY=socks5://localhost:8228
  export HTTP_PROXY=socks5://localhost:8228

  Or per-command:  curl --socks5-hostname localhost:8228 <url>

  Session started : 09:14 PDT
  Session expires : 21:14 PDT  (Entra ID 12h limit)
```

Leave that terminal window open — the tunnel stays up as long as it's running.
Press **Ctrl+C** when you're done to close it cleanly.

---

## Using the proxy

You've got three easy ways to send traffic through the tunnel.

**1. The browser it opened for you**
The simplest path. The new Edge/Chrome window is already wired to the proxy —
just start browsing to private endpoints.

**2. Set it for your whole shell session**
Everything in that terminal now goes through the proxy:

```bash
# macOS / Linux / Git Bash
export HTTPS_PROXY=socks5://localhost:8228
export HTTP_PROXY=socks5://localhost:8228
```

```powershell
# PowerShell
$env:HTTPS_PROXY = 'socks5://localhost:8228'
$env:HTTP_PROXY  = 'socks5://localhost:8228'
```

**3. One command at a time**
When you only want a single request to use it:

```bash
curl --socks5-hostname localhost:8228 <url>
```

> **Tip:** if the script told you it's using a different port (because `8228`
> was busy), use that number instead.

---

## Good to know

**Your session lasts 12 hours.** That's an Entra ID sign-in limit, not a choice
the script makes. You'll get a heads-up about an hour before it expires, and the
tunnel closes itself at the 12-hour mark. To keep going, just run the script
again to sign back in.

**The proxy is only ready once you see the confirmation.** It becomes usable the
moment the tunnel reports "ready" — give it those few seconds before pointing
tools at it.

**It cleans up after itself.** Whether you stop it with Ctrl+C or it hits the
time limit, the script shuts the tunnel down and tidies up its temporary files.

---

## When something goes wrong

The script is chatty on purpose — it narrates each step and prints details when
a check fails. A few common situations:

| What you see | What it means | What to do |
|--------------|---------------|------------|
| Browser sign-in didn't finish | The MFA prompt was cancelled or timed out | Run the script again and complete the sign-in |
| Tunnel connects, then drops | You're signed in, but not authorized on the VM | Ask your environment owner to confirm your "Virtual Machine Administrator Login" role |
| "VM is not running" | The jumpbox is stopped | Answer `y` when it offers to start it |
| Authentication errors after a while | Your 12-hour session expired | Run the script again to sign back in |
| "Port 8228 is in use" | Something else is on that port | Nothing — the script automatically picks the next free one and tells you which |

If the tunnel never comes up, the script prints the recent connection log to
help pinpoint why — most often it's the VM login role or a Bastion that isn't
fully provisioned yet.

---

*Both scripts are self-contained — no extra setup files, no manual installs.
Run, sign in, and you're inside the private network.*
