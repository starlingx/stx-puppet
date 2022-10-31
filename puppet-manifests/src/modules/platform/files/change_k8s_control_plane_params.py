# Copyright (c) 2021-2022 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0

import argparse
import logging
import os
import re
import signal
import subprocess
import sys
import time

from contextlib import contextmanager
from subprocess import CalledProcessError

import requests
import ruamel.yaml as yaml

# Logging
LOGGER_FORMAT = "%(asctime)s.%(msecs)03d %(process)d [%(levelname)s] " \
                "%(message)s"
LOGGER_NAME = 'k8s_control_plane_update'
LOG = logging.getLogger(LOGGER_NAME)
LOG.setLevel(logging.DEBUG)
root_logs = '/var/log/puppet/latest/'
if not os.path.exists(root_logs):
    os.makedirs(root_logs)
log_format = logging.Formatter(LOGGER_FORMAT)
fullname = os.path.join(root_logs, 'k8s_update.log')
fileHandler = logging.FileHandler(fullname)
fileHandler.setFormatter(log_format)
LOG.addHandler(fileHandler)
LOG.debug('Starting k8s update process.')

post_k8s_tasks = []

DEFAULT_TAG = 'platform::kubernetes::params::'
KUBE_APISERVER_TAG = 'platform::kubernetes::kube_apiserver::params::'
CONTROLLER_MANAGER_TAG = 'platform::kubernetes::kube_controller_manager::params::'
SCHEDULER_TAG = 'platform::kubernetes::kube_scheduler::params::'
ETCD_TAG = 'platform::kubernetes::params::etcd_'
CONFIG_TAG = 'platform::kubernetes::config::params::'
KUBELET_TAG = 'platform::kubernetes::kubelet::params::'
KUBE_APISERVER_CONFIG = '/etc/kubernetes/manifests/kube-apiserver.yaml'

REGEXPR_ADVERTISE_ADDRESS = r"advertise-address=(.*)\s"
APISERVER_READYZ_ENDPOINT = 'https://localhost:6443/readyz'
SCHEDULER_HEALTHZ_ENDPOINT = "https://127.0.0.1:10259/healthz"
CONTROLLER_MANAGER_HEALTHZ_ENDPOINT = "https://127.0.0.1:10257/healthz"
KUBELET_HEALTHZ_ENDPOINT = "http://localhost:10248/healthz"

RECOVERY_TIMEOUT = 5
RECOVERY_TRIES = 30
RECOVERY_TRY_SLEEP = 5


class TimeoutException(Exception):
    pass


@contextmanager
def time_limit(seconds):
    """Auxiliary function to limit execution time of a block of code."""
    def signal_handler(signum, frame):
        raise TimeoutException("TIMEOUT")
    signal.signal(signal.SIGALRM, signal_handler)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)


def _exec_cmd(cmd, stdout=None):
    """Auxiliary function to executes CLI commands.
    Return:
     - rc = 0, command was executed successfully.
     - rc = returncode, command failed.
    """
    rc = 0
    kwargs = {}
    if stdout is not None:
        kwargs["stdout"] = stdout
    try:
        subprocess.check_call(cmd, **kwargs)
    except CalledProcessError as e:
        LOG.error("return code: %s", e.returncode)
        rc = e.returncode
    return rc


def update_k8s_control_plane_components(config_filename,
                                        target_component='apiserver'):
    """The function updates a k8s control-plane component."""
    LOG.debug('Updating %s ...', target_component)
    cmd = ["kubeadm", "init", "phase", "control-plane",
           target_component, "--config", config_filename]
    rc = _exec_cmd(cmd)
    return rc


def update_k8s_kubelet(config_filename):
    """The function updates k8s kubelet."""
    LOG.debug('Updating k8s kubelet')
    cmd = ["kubeadm", "init", "phase", "kubelet-start",
           "--config", config_filename]
    rc = _exec_cmd(cmd)
    return rc


def patch_k8s_kubeadm_configmap(configmap_filename):
    """The function patches the kubeadm-config configmap."""
    LOG.debug('Patching k8s kubeadm configmap.')
    cmd = ["kubectl", "--kubeconfig=/etc/kubernetes/admin.conf", "-n", "kube-system",
           "patch", "configmap", "kubeadm-config", "--patch-file", configmap_filename]
    rc = _exec_cmd(cmd)
    return rc


def export_k8s_cluster_configuration(target_filename):
    """The function extracts from k8s kubeadm-config configmap the
    cluster configuration section and save it to a file.
    """
    LOG.debug('Exporting k8s cluster configuration.')
    rc = 0
    with open(target_filename, "w") as f:
        cmd = ["kubectl", "--kubeconfig=/etc/kubernetes/admin.conf", "get", "cm",
               "-n", "kube-system", "kubeadm-config",
               "-o=jsonpath={.data.ClusterConfiguration}"]
        rc = _exec_cmd(cmd, stdout=f)
    return rc


def export_k8s_kubeadm_configmap(target_filename):
    """The function exports k8s kubeadm-config configmap to a file."""
    LOG.debug('Exporting k8s kubeadm configmap.')
    rc = 0
    with open(target_filename, "w") as f:
        cmd = ["kubectl", "--kubeconfig=/etc/kubernetes/admin.conf", "get",
               "configmap", "kubeadm-config", "-o=yaml", "-n", "kube-system"]
        rc = _exec_cmd(cmd, stdout=f)
    return rc


def k8s_health_check(timeout, tries, try_sleep, healthz_endpoint):
    """The function checks a k8s control-plane component health.
    It uses the health endpoints provided by the control-plane pods.
    """
    # pylint: disable-msg=broad-except
    rc = False
    _tries = tries

    valid_endpoints = {
        APISERVER_READYZ_ENDPOINT: 'apiserver',
        SCHEDULER_HEALTHZ_ENDPOINT: 'scheduler',
        CONTROLLER_MANAGER_HEALTHZ_ENDPOINT: 'controller_manager',
        KUBELET_HEALTHZ_ENDPOINT: 'kubelet'
    }
    if healthz_endpoint not in valid_endpoints:
        msg = "Invalid endpoint: {}".format(healthz_endpoint)
        LOG.error(msg)
        return rc
    endpoint_name = valid_endpoints.get(healthz_endpoint)

    while _tries:
        time.sleep(try_sleep)
        msg = "Checking {} healthz (Remaining tries: {}".format(endpoint_name, _tries)
        LOG.debug(msg)

        try:
            with time_limit(timeout):
                try:
                    kwargs = {"verify": False, "timeout": 15}
                    r = requests.get(healthz_endpoint, **kwargs)
                    if r.status_code == 200:
                        rc = True
                        break
                except Exception as e:
                    msg = "{}".format(e)
                    LOG.error(msg)
                    rc = False
        except TimeoutException:
            LOG.error('Timeout while checking k8s control-plane component health')
            rc = False
        _tries -= 1
    return rc


def merge_configmap_files(lastest_configmap_file, bak_configmap_file,
                          new_configmap_file):
    """This function merges two kubeadmin-config configmap files and generates
    a new one as result. The first configmap is taken as reference and the
    cluster config section is replaced using the info of the second configmap.
    """
    # To patch the kubeadm-config configmap is neccesary to
    # start the mods from the last saved configmap (it is saved with a
    # version number), so we will take as source the last saved
    # configmap and we will replace in it only the cluster config section taken
    # from the backup kubeadm-config configmap.
    LOG.debug('Merging configmap files.')
    try:
        with open(lastest_configmap_file, 'r') as file:
            lastest_configmap = yaml.load(file, Loader=yaml.RoundTripLoader)

        with open(bak_configmap_file, 'r') as file:
            bak_configmap = yaml.load(file, Loader=yaml.RoundTripLoader)
            bak_cluster_config = yaml.load(
                bak_configmap['data']['ClusterConfiguration'],
                Loader=yaml.RoundTripLoader)
    except Exception as e:
        LOG.error('ERROR loading configmap file. %s ', e)
        raise

    cluster_cfg_str = yaml.dump(
        bak_cluster_config, Dumper=yaml.RoundTripDumper,
        default_flow_style=False)
    # ensure the yaml is constructed with proper formatting and tabbing
    cluster_cfg_str = yaml.scalarstring.PreservedScalarString(cluster_cfg_str)

    lastest_configmap['data']['ClusterConfiguration'] = cluster_cfg_str

    try:
        with open(new_configmap_file, 'w') as file:
            yaml.dump(lastest_configmap, file, Dumper=yaml.RoundTripDumper,
                      default_flow_style=False)
    except Exception as e:
        LOG.error('ERROR saving configmap file. %s', e)
        raise


def pre_k8s_updating_tasks(post_tasks=None):
    """The function execute a group of tasks that are needed before the
    k8s cluster is updated.
    Args:
        post_tasks: is anarray that contains callable object to be ejecuted
        in post_k8s_updating_tasks method
    """
    # pylint: disable-msg=broad-except
    rc = 0
    LOG.debug('Running mandatory tasks before update proccess start.')
    try:
        with open(KUBE_APISERVER_CONFIG) as f:
            lines = f.read()
    except Exception as e:
        LOG.error('Loading kube_apiserver config [Detail %s].', e)
        return 1

    m = re.search(REGEXPR_ADVERTISE_ADDRESS, lines)
    if m:
        advertise_address = m.group(1)
        LOG.debug('  advertise_address = %s', advertise_address)

    def _post_task_update_advertise_address():
        """This method will be executed in right after control plane has been initialized and it
        will update advertise_address in manifests/kube-apiserver.yaml to use mgmt address
        instead of oam address due to https://bugs.launchpad.net/starlingx/+bug/1900153
        """
        default_network_interface = None

        with open(KUBE_APISERVER_CONFIG) as f:
            lines = f.read()
        m = re.search(REGEXPR_ADVERTISE_ADDRESS, lines)
        if m:
            default_network_interface = m.group(1)
            LOG.debug('  default_network_interface = %s', default_network_interface)

        if advertise_address and default_network_interface \
           and advertise_address != default_network_interface:
            cmd = ["sed", "-i", "/oidc-issuer-url/! s/{}/{}/g".format(default_network_interface, advertise_address),
                   KUBE_APISERVER_CONFIG]
            _ = _exec_cmd(cmd)

    def _post_task_security_context():
        cmd = ["sed", "-i", "/securityContext:/,/type: RuntimeDefault/d", KUBE_APISERVER_CONFIG]
        _ = _exec_cmd(cmd)

    post_tasks.append(_post_task_update_advertise_address)
    post_tasks.append(_post_task_security_context)

    return rc


def post_k8s_updating_tasks(post_tasks=None):
    """The function executes tasks that are needed after the
    k8s cluster is updated.
    """
    if post_tasks:
        for task in post_tasks:
            if callable(task):
                task()
    LOG.debug('Running mandatory tasks after updating proccess has finished.')


def restore_k8s_configuration(kubeadm_cm_bak_file, cluster_config_bak_file,
                              configmap_patched_file, **kwargs):
    """The funtion restores the k8s control-plane configuration and updates the kubeadm
    configmap with the backup configuration to keep it sync.
    Return:
     - 1, Backup configuration has been restored successfully.
     - 2, Restore process has failed.
    """
    LOG.debug('Initializing restore')

    configmap_latest_file = kwargs.get(
        'configmap_latest_file', '/tmp/cluster_configmap_latest.yaml')
    tries = kwargs.get('tries')
    try_sleep = kwargs.get('try_sleep')
    timeout = kwargs.get('timeout')

    # -------------------------------------------------------------------------
    # Restore kube-apiserver with backup configuration
    # -------------------------------------------------------------------------
    # First we need to restore apiserver with saved cluster_configuration
    update_k8s_control_plane_components(
        cluster_config_bak_file, target_component='apiserver')

    # Run mandatory tasks after the update proccess has finished
    post_k8s_updating_tasks(post_k8s_tasks)

    # Restarting Kubelet
    LOG.debug('Restarting Kubelet')
    cmd = ["systemctl", "restart", "kubelet.service"]
    if not _exec_cmd(cmd) == 0:
        return 2

    # Wait for kube-apiserver to be up before executing next steps
    k8s_apiserver_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=APISERVER_READYZ_ENDPOINT)
    if not k8s_apiserver_healthy:
        return 2

    # Restore controller_manager
    update_k8s_control_plane_components(
        cluster_config_bak_file, target_component='controller-manager')

    k8s_component_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=CONTROLLER_MANAGER_HEALTHZ_ENDPOINT)
    if not k8s_component_healthy:
        return 2

    # Restore scheduler
    update_k8s_control_plane_components(
        cluster_config_bak_file, target_component='scheduler')

    k8s_component_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=SCHEDULER_HEALTHZ_ENDPOINT)
    if not k8s_component_healthy:
        return 2

    # Patch kubeadm configmap to keep it consistent with the applied config.
    LOG.debug('k8s control-plane is healthy: initializing configmap patching.')
    export_k8s_kubeadm_configmap(configmap_latest_file)

    merge_configmap_files(configmap_latest_file, kubeadm_cm_bak_file,
                          configmap_patched_file)

    patch_k8s_kubeadm_configmap(configmap_patched_file)
    return 1


def _validate_admission_plugins(custom_plugins):
    """The function complements the plugins set by user with those required by
    the system.
    """
    # There are some plugins required by the system
    # if the plugins is specified manually, these ones might
    # be missed. We will add these automatically so the user
    # does not need to keep track of them
    required_plugins = ['NodeRestriction']
    for plugin in required_plugins:
        if plugin not in custom_plugins:
            custom_plugins = custom_plugins + "," + plugin
    return custom_plugins


def main():
    """This script updates the k8s control-plane components configuration
    with the paramaters set by the user through sysinv service-parameters.
    If a failure is detected during the update process a full restore is
    applied using the latest valid configuration.

    Sections
    ---------
    The service-parameter 'kubernetes' service sections are:
    - 'kube_apiserver'
    - 'kube_controllerManager',
    - 'kube_scheduler'
    - 'kubelet'
    for the respective control-plane components.
    The user can add, modify or delete the parameters of k8s control-plane
    components under these sections.

    Field Names:
    ------------
    service-parameter fields should be named following the k8s nomenclature,
    used in kubeadm.conf file. Currently there are some parameters that are
    defined with name fields that not match the names expected by k8s components
    APIs. The apiserver_schema, scheduler_schema, controller_manager_schema and
    etc_schema are used to rebuild the structure of that sections and to
    translate the fields that not match k8s expected names.
    i.e.: service-parameters accept "admission_plugins" but the name expected by
    k8s for this field is "enabled-admission-plugins", so a translation is
    needed.

    Recovery:
    ---------
    - Automatic Recovery
    After an update process a monitor is activated to check kube-apiserver
    health. If something goes wrong and kube-apiserver go out of service a
    recovery process is initiated to restore it. This function is activated
    by default. The user also can set a flag to deactivate this recovery process
    only for debugging purpose. Also is possible to set timeout, tries and
    try_sleep of k8s health check.
    Those variables must be defined in the 'config' section of 'platform'
    service throught service-parameters:
      automatic_recovery: true|false
      timeout: <seconds>
      tries: <number>
      try_sleep: <seconds>

    Steps:
      - Read the new configuration from puppet files (hieradata).
      - Prepare the ClusterConfiguration to update control-plane components.
      - Execute some task before updating control-plane components.
      - Update control-plane configuration.
      - Execute some task after updating control-plane components.
      - Check k8s control-plane components healthz after the update process.
      - Trigger restore configuration from backup if the update process failed.
      - Update backup files if the update process finished successfully.

    Returns:
     - rc = 0, K8s control-plane components has been updated successfully.
     - rc = 1, The updating process failed but backup configuration has been applied.
               Sysinv won't clear the alarm 250.001 - Configuration is out-of-date.
     - rc = 2, The updating process failed. One ore more control-plane
               components could be down.
     - rc = 3, The updating process failed.
    """
    # pylint: disable-msg=too-many-locals
    # pylint: disable-msg=too-many-branches
    # pylint: disable-msg=too-many-statements
    # pylint: disable-msg=too-many-return-statements
    # pylint: disable-msg=broad-except

    # Components Schemas
    # The 'kubernetes' service in service-parameter has a section per k8s
    # component to manage its configurations. Only the 'extraVolumes' parameters
    # are saved in a different section (check available sections in module
    # description)
    # The kubeadm command (used to update components), however, expects a
    # configuration file with a different structure per component. Each component
    # has also different sections, for example: root, extraArgs, etc.
    # Therefore, these schemas are created to map the (sysinv) service parameters
    # kubernetes sections to the expected structure.
    apiserver_schema = {
        'root': {
            'timeoutForControlPlane': 'timeoutForControlPlane'
        },
        'extraArgs': {
            'oidc_issuer_url': 'oidc-issuer-url',
            'oidc_client_id': 'oidc-client-id',
            'oidc_username_claim': 'oidc-username-claim',
            'oidc_groups_claim': 'oidc-groups-claim',
            'admission_plugins': 'enable-admission-plugins',
        },
        'extraVolumes': {},
    }

    controller_manager_schema = {
        'root': {},
    }

    scheduler_schema = {
        'root': {},
    }

    etcd_schema = {
        'root': {},
        'external': {
            'etcd_cafile': 'caFile',
            'etcd_certfile': 'certFile',
            'etcd_keyfile': 'keyFile',
            'etcd_servers': 'endpoints'
        }
    }

    # Args Parameters
    parser = argparse.ArgumentParser()
    parser.add_argument("--hieradata_path", default="/tmp/puppet/hieradata")
    parser.add_argument("--hieradata_file", default="system.yaml")
    parser.add_argument("--backup_path", default="/etc/kubernetes/backup")
    parser.add_argument("--kubeadm_cm_file", default="/tmp/cluster_configmap.yaml")
    parser.add_argument("--kubeadm_cm_bak_file", default="configmap.yaml")
    parser.add_argument("--configmap_patched_file",
                        default="/tmp/cluster_configmap_patched.yaml")
    parser.add_argument("--cluster_config_file", default="/tmp/cluster_config.yaml")
    parser.add_argument("--cluster_config_bak_file", default="cluster_config.yaml")

    parser.add_argument("--automatic_recovery", default=True)
    parser.add_argument("--timeout", default=RECOVERY_TIMEOUT)
    parser.add_argument("--tries", default=RECOVERY_TRIES)
    parser.add_argument("--try_sleep", default=RECOVERY_TRY_SLEEP)

    parser.add_argument("--etcd_cafile", default='')
    parser.add_argument("--etcd_certfile", default='')
    parser.add_argument("--etcd_keyfile", default='')
    parser.add_argument("--etcd_servers", default='')
    args = parser.parse_args()

    hieradata_file = os.path.join(args.hieradata_path, args.hieradata_file)
    kubeadm_cm_file = args.kubeadm_cm_file
    kubeadm_cm_bak_file = os.path.join(args.backup_path, args.kubeadm_cm_bak_file)
    cluster_config_file = args.cluster_config_file
    cluster_config_bak_file = os.path.join(args.backup_path, args.cluster_config_bak_file)
    configmap_patched_file = args.configmap_patched_file

    automatic_recovery = args.automatic_recovery
    timeout = args.timeout
    tries = args.tries
    try_sleep = args.try_sleep

    etcd_cafile = args.etcd_cafile
    etcd_certfile = args.etcd_certfile
    etcd_keyfile = args.etcd_keyfile
    etcd_servers = args.etcd_servers

    rc = 2

    # -----------------------------------------------------------------------------
    # Backup k8s kubeadm configmap and cluster configuration, if not exist
    # -----------------------------------------------------------------------------
    # This flag will avoid any error when you try to run this script manually
    # and kube-apiserver is down.
    is_k8s_apiserver_up = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=APISERVER_READYZ_ENDPOINT)

    if not os.path.isfile(kubeadm_cm_bak_file) or\
            not os.path.isfile(cluster_config_bak_file):
        LOG.debug("No k8s backup files founded.")
        if is_k8s_apiserver_up:
            LOG.debug("Creating backup from current k8s config.")
            export_k8s_kubeadm_configmap(kubeadm_cm_bak_file)
            export_k8s_cluster_configuration(cluster_config_bak_file)
        else:
            msg = "Apiserver is down and there is not backup file."
            LOG.error(msg)
            return 2

    # -----------------------------------------------------------------------------
    # Load current applied k8s cluster configuration
    # -----------------------------------------------------------------------------
    LOG.debug('Exporting current config to file.')
    if export_k8s_kubeadm_configmap(kubeadm_cm_file) != 0:
        LOG.debug("k8s is not running, copy configmap backup file")
        cmd = ["cp", kubeadm_cm_bak_file, kubeadm_cm_file]

        if _exec_cmd(cmd) != 0:
            msg = "Fail copying configmap backup file."
            LOG.error(msg)
            return 3

    try:
        LOG.debug('Loading current config from file.')
        with open(kubeadm_cm_file, 'r') as file:
            kubeadm_cfg = yaml.load(file, Loader=yaml.RoundTripLoader)
            cluster_cfg = yaml.load(
                kubeadm_cfg['data']['ClusterConfiguration'], Loader=yaml.RoundTripLoader)
    except FileNotFoundError as e:
        msg = str('Loading configmap from file. {}'.format(e))
        LOG.error(msg)
        return 3

    # -----------------------------------------------------------------------------
    # Load new k8s cluster config from hieradata
    # (updated by user through sysinv > service-parameter)
    # -----------------------------------------------------------------------------
    try:
        with open(hieradata_file, 'r') as _hieradata:
            hieradata = yaml.load(_hieradata, Loader=yaml.Loader)
    except Exception as e:
        LOG.error('ERROR loading hieradata. %s', e)
        return 3

    service_params = {'apiServer': {}, 'controllerManager': {},
                      'scheduler': {}, 'etcd': {}, 'config': {},
                      'kubelet': {}}
    for param_key, value in hieradata.items():
        if param_key.startswith(KUBE_APISERVER_TAG):
            param_name = param_key.split(KUBE_APISERVER_TAG)[1]
            for sect in apiserver_schema.keys():
                if param_name in apiserver_schema[sect].keys():
                    param_name = apiserver_schema[sect][param_name]
            service_params['apiServer'][param_name] = value

        elif param_key.startswith(CONTROLLER_MANAGER_TAG):
            param_name = param_key.split(CONTROLLER_MANAGER_TAG)[1]
            for sect in controller_manager_schema.keys():
                if param_name in controller_manager_schema[sect].keys():
                    param_name = controller_manager_schema[sect][param_name]
            service_params['controllerManager'][param_name] = value

        elif param_key.startswith(SCHEDULER_TAG):
            param_name = param_key.split(SCHEDULER_TAG)[1]
            for sect in scheduler_schema.keys():
                if param_name in scheduler_schema[sect].keys():
                    param_name = scheduler_schema[sect][param_name]
            service_params['scheduler'][param_name] = value

        elif param_key.startswith(ETCD_TAG):
            param_name = param_key.split(DEFAULT_TAG)[1]
            for sect in etcd_schema.keys():
                if param_name in etcd_schema[sect].keys():
                    param_name = etcd_schema[sect][param_name]
            service_params['etcd'][param_name] = value

        elif param_key.startswith(CONFIG_TAG):
            param_name = param_key.split(CONFIG_TAG)[1]
            service_params['config'][param_name] = value

        elif param_key.startswith(KUBELET_TAG):
            param_name = param_key.split(KUBELET_TAG)[1]
            service_params['kubelet'][param_name] = value

    # -----------------------------------------------------------------------------
    # Replace new config (from hieradata) into current (preloaded)
    # cluster config dict
    # -----------------------------------------------------------------------------
    # Config section --------------------------------------------------------------
    if 'automatic_recovery' in service_params['config'].keys():
        # this value is set by sysinv, and its values are 'true' or 'false'
        value = service_params['config']['automatic_recovery']
        automatic_recovery = value == 'true'

    if 'timeout' in service_params['config'].keys():
        timeout = int(service_params['config']['timeout'])

    if 'tries' in service_params['config'].keys():
        tries = int(service_params['config']['tries'])

    if 'try_sleep' in service_params['config'].keys():
        try_sleep = int(service_params['config']['try_sleep'])

    # Update kube-apiserver section -----------------------------------------------
    # By default all not known params will be placed in section 'extraArgs'
    for param, value in service_params['apiServer'].items():
        if param in apiserver_schema['root'].keys():
            cluster_cfg['apiServer'][param] = value

        else:
            if 'extraArgs' not in cluster_cfg['apiServer'].keys():
                cluster_cfg['apiServer']['extraArgs'] = {}
            if param == 'enable-admission-plugins':
                value = _validate_admission_plugins(value)
                cluster_cfg['apiServer']['extraArgs'][param] = value
            else:
                cluster_cfg['apiServer']['extraArgs'][param] = value

    # remove all parameters not present in service-parameter.
    if 'extraArgs' in cluster_cfg['apiServer'].keys():
        for param in list(cluster_cfg['apiServer']['extraArgs'].keys()):
            if param not in service_params['apiServer']:
                cluster_cfg['apiServer']['extraArgs'].pop(param)

    # Update controller manager section -------------------------------------------
    # By default all not known params will be place in section 'extraArgs'
    for param, value in service_params['controllerManager'].items():
        if param in controller_manager_schema['root'].keys():
            cluster_cfg['controllerManager'][param] = value
        else:
            if 'extraArgs' not in cluster_cfg['controllerManager'].keys():
                cluster_cfg['controllerManager']['extraArgs'] = {}
            cluster_cfg['controllerManager']['extraArgs'][param] = value

    # remove all parameters not present in service-parameter.
    if 'extraArgs' in cluster_cfg['controllerManager'].keys():
        for param in list(cluster_cfg['controllerManager']['extraArgs'].keys()):
            if param not in service_params['controllerManager']:
                cluster_cfg['controllerManager']['extraArgs'].pop(param)

    # Update scheduler section ----------------------------------------------------
    # By default all not known params will be place in section 'extraArgs'
    for param, value in service_params['scheduler'].items():
        if param in scheduler_schema['root'].keys():
            cluster_cfg['scheduler'][param] = value

        else:
            if 'extraArgs' not in cluster_cfg['scheduler'].keys():
                cluster_cfg['scheduler']['extraArgs'] = {}
            cluster_cfg['scheduler']['extraArgs'][param] = value

    # remove all parameters not present in service-parameter.
    if 'extraArgs' in cluster_cfg['scheduler'].keys():
        for param in list(cluster_cfg['scheduler']['extraArgs'].keys()):
            if param not in service_params['scheduler']:
                cluster_cfg['scheduler']['extraArgs'].pop(param)

    # Update etcd section ---------------------------------------------------------
    for param, value in service_params['etcd'].items():
        # Prioritize user-defined arguments, otherwise, the values are taken from hieradata.
        value = etcd_cafile if param == 'caFile' and etcd_cafile else value
        value = etcd_certfile if param == 'certFile' and etcd_certfile else value
        value = etcd_keyfile if param == 'keyFile' and etcd_keyfile else value
        value = etcd_servers if param == 'endpoints' and etcd_servers else value

        # By default all not known params will be place in section 'external'
        if param in etcd_schema['root'].keys():
            cluster_cfg['etcd'][param] = value
        else:
            # params saved like list (value should be separated by comma)
            if param == 'endpoints':
                cluster_cfg['etcd']['external'][param] = value.split(',')
            # by default params are saved like strings
            else:
                cluster_cfg['etcd']['external'][param] = value

    # -----------------------------------------------------------------------------
    # Pre updating tasks and patch kubeadm configmap
    # -----------------------------------------------------------------------------
    # Save updated kubeadm-config into file
    cluster_cfg_str = yaml.dump(
        cluster_cfg, Dumper=yaml.RoundTripDumper, default_flow_style=False)

    # ensure the yaml is constructed with proper formatting and tabbing
    cluster_cfg_str = yaml.scalarstring.PreservedScalarString(cluster_cfg_str)

    kubeadm_cfg['data']['ClusterConfiguration'] = cluster_cfg_str

    try:
        with open(kubeadm_cm_file, 'w') as file:
            yaml.dump(kubeadm_cfg, file, Dumper=yaml.RoundTripDumper,
                      default_flow_style=False)
    except Exception as e:
        LOG.error('Saving updated kubeadm-config into file. %s', e)
        return 3

    # Run mandatory tasks before the update proccess starts
    if pre_k8s_updating_tasks(post_k8s_tasks) != 0:
        LOG.error('Running pre updating tasks.')
        return 3

    # Patch kubeadm-config configmap with the updated configuration.
    if patch_k8s_kubeadm_configmap(kubeadm_cm_file) != 0:
        LOG.error('Parching kubeadm-config configmap.')
        return 3

    # Export the updated k8s cluster configuration
    if export_k8s_cluster_configuration(cluster_config_file) != 0:
        LOG.error('Exportando k8s cluster configuration.')
        return 3

    # -----------------------------------------------------------------------------
    # Update k8s kube-apiserver
    # -----------------------------------------------------------------------------
    update_k8s_control_plane_components(
        cluster_config_file, target_component='apiserver')

    # Wait for kube-apiserver to be up before executing next steps
    is_k8s_apiserver_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=APISERVER_READYZ_ENDPOINT)

    # Check kube-apiserver health, then backup and restore
    if automatic_recovery:
        if not is_k8s_apiserver_healthy:
            LOG.debug('kube-apiserver is not responding, intializing restore.')
            restore_rc = restore_k8s_configuration(
                kubeadm_cm_bak_file, cluster_config_bak_file, configmap_patched_file,
                tries=tries, try_sleep=try_sleep, timeout=timeout)
            if restore_rc == 2:
                LOG.error("kube-apiserver has failed to start using backup configuration.")
                return 2
            if restore_rc == 1:
                return 1

    # Run mandatory tasks after the update proccess has finished
    post_k8s_updating_tasks(post_k8s_tasks)

    # -----------------------------------------------------------------------------
    # Update k8s kube-controller-manager
    # -----------------------------------------------------------------------------
    update_k8s_control_plane_components(
        cluster_config_file, target_component='controller-manager')

    # Wait for controller-manager to be up
    is_k8s_component_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=CONTROLLER_MANAGER_HEALTHZ_ENDPOINT)

    # Check kube-controller-manager health, then backup and restore
    if automatic_recovery:
        if not is_k8s_component_healthy:
            LOG.debug('kube-controller-manager is not responding, intializing restore.')
            restore_rc = restore_k8s_configuration(
                kubeadm_cm_bak_file, cluster_config_bak_file, configmap_patched_file,
                tries=tries, try_sleep=try_sleep, timeout=timeout)

            if restore_rc == 2:
                msg = "kube-controller-manager has failed to start" +\
                      "using backup configuration."
                LOG.error(msg)
                return 2
            if restore_rc == 1:
                return 1

    # -----------------------------------------------------------------------------
    # Update k8s kube-scheduler
    # -----------------------------------------------------------------------------
    update_k8s_control_plane_components(
        cluster_config_file, target_component='scheduler')

    # Wait for controller-manager to be up
    LOG.debug('Waiting for kube-scheduler be online.')
    is_k8s_component_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=SCHEDULER_HEALTHZ_ENDPOINT)

    # Check kube-scheduler health, then backup and restore
    if automatic_recovery:
        if not is_k8s_component_healthy:
            LOG.debug('kube-scheduler is not responding, intializing restore.')
            restore_rc = restore_k8s_configuration(
                kubeadm_cm_bak_file, cluster_config_bak_file, configmap_patched_file,
                tries=tries, try_sleep=try_sleep, timeout=timeout)
            if restore_rc == 2:
                LOG.error("kube-scheduler has failed to start using backup configuration.")
                return 2
            if restore_rc == 1:
                return 1

    # -----------------------------------------------------------------------------
    # if all the k8s control-plane components are up and running make a backup
    # -----------------------------------------------------------------------------
    LOG.debug("Updating backup files with latest configuration ...")
    LOG.debug("Check all k8s control-plane components are up and running.")
    is_k8s_apiserver_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=APISERVER_READYZ_ENDPOINT)
    is_k8s_controller_manager_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=CONTROLLER_MANAGER_HEALTHZ_ENDPOINT)
    is_k8s_scheduler_healthy = k8s_health_check(
        timeout=timeout, try_sleep=try_sleep, tries=tries,
        healthz_endpoint=SCHEDULER_HEALTHZ_ENDPOINT)

    if is_k8s_apiserver_healthy and is_k8s_controller_manager_healthy and\
            is_k8s_scheduler_healthy:
        # Update backup files with latest configuration
        export_k8s_kubeadm_configmap(kubeadm_cm_bak_file)
        export_k8s_cluster_configuration(cluster_config_bak_file)
        LOG.debug("SUCCESSFULLY UPDATED.")
        return 0

    return rc


if __name__ == "__main__":
    sys.exit(main())
