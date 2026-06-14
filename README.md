# mship-workspace

The coordination workspace (metarepo) for the **Mothership** family. It holds the `mship`
configuration that ties the repos together, so cross-repo workflows run from one place.

## Repos coordinated

Members live as **gitignored subdirectories** of this workspace — each is its own
git repo, tracked there, never committed here:

- [`mothership`](https://github.com/atomikpanda/mothership) — the cross-repo workflow CLI (`mship`).
- [`ground-control`](https://github.com/atomikpanda/ground-control) — the mobile spec cockpit.

## Setup

Clone the workspace, then clone the members **into** it, then drive `mship` from here:

```bash
git clone https://github.com/atomikpanda/mship-workspace
cd mship-workspace
git clone https://github.com/atomikpanda/mothership
git clone https://github.com/atomikpanda/ground-control
mship status   # resolves the workspace and both members
```

The member dirs are `.gitignore`d, so `mship` commands (`spawn`, `status`, `audit`,
`spec`, …) operate on the whole family from here without the workspace repo tracking
the members. (If you already have a `mothership` checkout, symlink it in instead of
re-cloning: `ln -s /path/to/mothership ./mothership`.)

## License

MIT — see [LICENSE](LICENSE).
