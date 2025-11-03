#
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2019-2024 Intel Corporation
#

BINDIR ?= /usr/local/bin
CONFIGDIR ?= /etc/puppet
MODULEDIR ?= /usr/share/puppet/modules

install:
ifdef ignore_puppet_warnings
	install -m 755 -D bin/puppet-manifest-apply-ignore-warnings.sh $(BINDIR)/puppet-manifest-apply.sh
else
	install -m 755 -D bin/puppet-manifest-apply.sh $(BINDIR)/puppet-manifest-apply.sh
endif
	install -m 755 -D bin/apply_network_config.py $(BINDIR)/apply_network_config.py
	install -m 755 -D bin/k8s_wait_for_endpoints_health.py $(BINDIR)/k8s_wait_for_endpoints_health.py
	install -m 755 -D bin/kube-wait-control-plane-terminated.sh $(BINDIR)/kube-wait-control-plane-terminated.sh
	install -m 755 -D bin/puppet-update-default-grub.sh $(BINDIR)/puppet-update-default-grub.sh
	install -m 755 -D bin/puppet-update-grub-env.py $(BINDIR)/puppet-update-grub-env.py
	install -m 755 -D bin/remove_unused_calico_hostendpoints.sh $(BINDIR)/remove_unused_calico_hostendpoints.sh
	install -m 755 -D bin/calico_firewall_apply_hostendp.sh $(BINDIR)/calico_firewall_apply_hostendp.sh
	install -m 755 -D bin/calico_firewall_apply_policy.sh $(BINDIR)/calico_firewall_apply_policy.sh
	install -m 755 -D bin/kubelet-cleanup-orphaned-volumes.sh $(BINDIR)/kubelet-cleanup-orphaned-volumes.sh
	install -m 755 -D bin/check_ipv6_tentative_addresses.py $(BINDIR)/check_ipv6_tentative_addresses.py
	install -m 755 -D bin/manage_partitions_pre_script.sh $(BINDIR)/manage_partitions_pre_script.sh
	install -m 755 -D bin/dual-stack-kubelet.py $(BINDIR)/dual-stack-kubelet.py
	install -m 755 -D bin/dual-stack-kubeadm.py $(BINDIR)/dual-stack-kubeadm.py
	install -m 755 -D bin/dual-stack-kubeproxy.py $(BINDIR)/dual-stack-kubeproxy.py
	install -m 755 -D bin/dual-stack-calico.py $(BINDIR)/dual-stack-calico.py
	install -m 755 -D bin/dual-stack-multus.py $(BINDIR)/dual-stack-multus.py
	install -m 755 -D bin/verify-systemd-running.sh $(BINDIR)/verify-systemd-running.sh

	install -d -m 0755 $(CONFIGDIR)
ifdef hiera_v5
	install -m 640 etc/hiera_v5.yaml $(CONFIGDIR)/hiera.yaml
else
	install -m 640 etc/hiera.yaml $(CONFIGDIR)
endif
	cp -R hieradata $(CONFIGDIR)/
	cp -R manifests $(CONFIGDIR)/
	install -d -m 0755 $(MODULEDIR)
	cp -R modules/platform $(MODULEDIR)/
	cp -R modules/openstack $(MODULEDIR)/
