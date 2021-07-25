#!/usr/bin/env python3

import glob
import os
import sys

from subprocess import Popen, DEVNULL


class Yocto:
    '''
    Yocto build wrapper.

    Attributes:
        image (str): Yocto image to be built (default to core-image-minimal).
        cmd_prefix (str): Prefix any Yocto command with this command which source 'oe-init-build-env' script to prepare Yocto build environment.
    '''

    def __init__(self):
        self.image = os.environ.get('IMAGE', 'core-image-minimal')
        # Set allowed Yocto environment variables
        os.environ['BB_ENV_EXTRAWHITE'] = os.environ.get('BB_ENV_EXTRAWHITE', " \
                DISTRO \
                DL_DIR \
                MACHINE \
                SSTATE_DIR \
                ACCEPT_FSL_EULA \
            ")

        # Find Yocto build environment setup script
        oe_init_build_env = glob.glob(
            "./layers/**/oe-init-build-env", recursive=True)

        # Only one script should exist
        assert len(oe_init_build_env) == 1, \
            "Only one 'oe-init-build-env' can be used, several found: \n" \
            + str(oe_init_build_env)
        self.cmd_prefix = ". " + os.path.abspath(oe_init_build_env[0]) + " ; "

        self._add_layers()

    def _add_layers(self):
        '''
        Parse all existing layers under layers/ directory and  add them to '<yocto_build_directory>/conf/bblayers.conf'.
        Display Yocto layers list successfully added.
        '''

        layers = glob.glob(
            "./layers/**/meta-*/conf/layer.conf", recursive=True)
        layers = list(map(lambda x: os.path.abspath(
            x.replace('/conf/layer.conf', '')), layers))

        cmd = "bitbake-layers add-layer"
        for layer in layers:
            cmd = cmd + " " + layer

        self.run(cmd, console=True)

        for layer in layers:
            print("Layer '" + layer + "' added.")

    def run(self, cmd, console=False):
        '''
        Run a given command into Yocto environment and display its output on console if asked.

        Arguments:
            cmd (str): Command to run.
            console (Boolean): Flag to display or not command outputs (stdout and stderr).
        '''
        cmd = self.cmd_prefix + cmd
        if console:
            output = None
        else:
            output = DEVNULL
        p = Popen(cmd, executable="/bin/bash",
                  stdout=output, stderr=output, shell=True)
        p.wait()


if __name__ == "__main__":
    yocto = Yocto()
    if len(sys.argv) > 1:
        yocto.run(' '.join(sys.argv[1:]), console=True)
    else:
        yocto.run('bitbake ' + yocto.image, console=True)
