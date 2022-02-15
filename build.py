#!/usr/bin/env python3

import os
from pathlib import Path
import subprocess
import sys

class Yocto:
    SHELL = "/bin/bash"

    '''
    Yocto build wrapper.

    Attributes:
        image (str): Yocto image to be built (default to core-image-minimal).
        cmd_prefix (str): Prefix any Yocto command with this command which source 'oe-init-build-env' script to prepare Yocto build environment.
    '''

    def __init__(self):
        self.image = os.environ.get('IMAGE', 'core-image-minimal')
        # Set allowed Yocto environment variables
        os.environ['BB_ENV_PASSTHROUGH_ADDITIONS'] = os.environ.get('BB_ENV_PASSTHROUGH_ADDITIONS', " \
                DISTRO \
                DL_DIR \
                MACHINE \
                SSTATE_DIR \
                ACCEPT_FSL_EULA \
            ")

        # Find Yocto build environment setup script
        self.layer_path = Path('layers')
        oe_init_build_env = list(self.layer_path.glob("**/oe-init-build-env"))

        # Only one script should exist
        assert len(oe_init_build_env) == 1, \
            f"Only one 'oe-init-build-env' can be used, several found: {oe_init_build_env}\n"
        self.cmd_prefix = f". {oe_init_build_env[0].resolve()};"

    def add_layers(self):
        '''
        Parse all existing layers under layers/ directory and  add them to '<yocto_build_directory>/conf/bblayers.conf'.
        Display Yocto layers list successfully added.
        '''

        layers = self.layer_path.glob("**/meta-*/conf/layer.conf")
        layers = [x.parent.parent.resolve() for x in layers]

        cmd = "bitbake-layers add-layer"
        for layer in layers:
            cmd = f"{cmd} {layer}"

        self.run(cmd, console=True)

        for layer in layers:
            print(f"Layer '{layer}' added.")

    def run(self, cmd, console=False):
        '''
        Run a given command into Yocto environment and display its output on console if asked.

        Arguments:
            cmd (str): Command to run.
            console (Boolean): Flag to display or not command outputs (stdout and stderr).
        '''
        cmd = f'{self.cmd_prefix + cmd}'
        subprocess.run(cmd, shell=True, check=True, executable=Yocto.SHELL,
                capture_output=(not console)
                )

if __name__ == "__main__":
    yocto = Yocto()
    yocto.add_layers()
    if len(sys.argv) > 1:
        yocto.run(' '.join(sys.argv[1:]), console=True)
    else:
        yocto.run('bitbake ' + yocto.image, console=True)
