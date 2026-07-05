# Ansible tests

Validate the roles and playbooks with:

```bash
cd ansible
yamllint .
ansible-lint playbooks/site.yml playbooks/validate.yml
ansible-playbook playbooks/site.yml --check --diff
```

`make validate` from the repository root runs `ansible-lint` when it is
installed.

## Check-mode limitations

Some tasks cannot report accurate results under `--check` because they depend on
state that only exists after real changes. These are guarded with
`when: not ansible_check_mode` or `check_mode: false` and are expected to be
skipped or no-ops during a dry run:

- **containerd**: `containerd config default` and writing `config.toml` are
  skipped in check mode because the binary is only present after the package is
  installed.
- **kubernetes-prerequisites**: `swapoff -a` and enabling `kubelet` are skipped;
  package installation reports as changed only after the `pkgs.k8s.io` repo is
  actually configured.
- **time-sync-validation**: `timedatectl`/`service_facts` run even in check mode
  (`check_mode: false`) so the assertions remain meaningful.

Run a full apply against a disposable VM to exercise the package, repository, and
kernel-module tasks end to end.
