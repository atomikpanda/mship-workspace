# mship-workspace

The coordination workspace (metarepo) for the **Mothership** family. It holds the `mship`
configuration that ties the repos together, so cross-repo workflows run from one place.

## Repos coordinated

Referenced in place as siblings (via `../`) — never relocated, each independently cloneable:

- [`mothership`](https://github.com/atomikpanda/mothership) — the cross-repo workflow CLI (`mship`).
- [`ground-control`](https://github.com/atomikpanda/ground-control) — the mobile spec cockpit.

## Setup

Clone all three as siblings, then drive `mship` from this directory:

```bash
mkdir mship && cd mship
git clone https://github.com/atomikpanda/mothership
git clone https://github.com/atomikpanda/ground-control
git clone https://github.com/atomikpanda/mship-workspace
cd mship-workspace
mship status   # resolves the workspace and both repos
```

`mothership.yaml` references the sibling repos via `../`, so `mship` commands
(`spawn`, `status`, `audit`, `spec`, …) operate on the whole family from here.

## License

MIT — see [LICENSE](LICENSE).
