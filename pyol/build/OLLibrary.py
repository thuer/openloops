
# Copyright 2014 Fabio Cascioli, Jonas Lindert, Philipp Maierhoefer, Stefano Pozzorini
#
# This file is part of OpenLoops.
#
# OpenLoops is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# OpenLoops is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with OpenLoops.  If not, see <http://www.gnu.org/licenses/>.


import os
import subprocess
import OLBaseConfig

config = OLBaseConfig.get_config()

class CPPContainer:
    """Container for source files scheduled for preprocessing."""

    cpp_script = os.path.join('pyol', 'build', 'cpp.scons')

    def __init__(self, mp_src = [], dp_src = [], version_src = [], mp = ['dp'],
                 version = 'none', revision = 'none', cpp_defs = [],
                 scons_cmd = config['scons_cmd'], version_macro = 'VERSION',
                 revision_macro = 'REVISION', kind_parameter = 'REALKIND',
                 target = 'cpp', target_prefix = ''):
        self.mp_src = list(mp_src)
        self.dp_src = list(dp_src)
        self.version_src = list(version_src)
        self.mp = list(mp)
        self.version = version
        self.revision = revision
        self.cpp_defs = [(cppdef,) if isinstance(cppdef, str) else cppdef for cppdef in cpp_defs]
        self.scons_cmd = scons_cmd
        self.version_macro = version_macro
        self.revision_macro = revision_macro
        self.kind_parameter = kind_parameter
        self.target = target
        self.target_prefix = target_prefix

    @staticmethod
    def src_path_mod(srcfile, prefix, suffix):
        path, filename = os.path.split(srcfile)
        return os.path.normpath(os.path.join(path, prefix + os.path.splitext(filename)[0] + suffix))

    def add(self, src_dir = '', mp_src = [], dp_src = [], version_src = []):
        mp_src = [os.path.join(src_dir, src) for src in mp_src]
        dp_src = [os.path.join(src_dir, src) for src in dp_src]
        version_src = [os.path.join(src_dir, src) for src in version_src]
        #self.mp_src.extend(mp_src)
        #self.mp_src += mp_src
        self.mp_src = self.mp_src + mp_src
        self.dp_src.extend(dp_src)
        self.version_src.extend(version_src)

        src_list = []
        for precision in self.mp:
            src_list.extend([CPPContainer.src_path_mod(srcfile,
                               self.target_prefix,
                               '_' + precision + os.path.splitext(srcfile)[1].lower())
                               for srcfile in mp_src])
        src_list.extend([CPPContainer.src_path_mod(srcfile,
                           self.target_prefix,
                           os.path.splitext(srcfile)[1].lower())
                           for srcfile in dp_src + version_src])

        return src_list

    def run(self, clean = False):
        import subprocess
        scons_flags = ['-Q']
        if clean:
            scons_flags.append('-c')

        success = subprocess.call([self.scons_cmd] + scons_flags + ['-f', self.cpp_script,
            'version=' + self.version,
            'revision=' + self.revision,
            'version_macro=' + self.version_macro,
            'revision_macro=' + self.revision_macro,
            'kind_parameter=' + self.kind_parameter,
            'mp_src=' + ','.join(self.mp_src),
            'dp_src=' + ','.join(self.dp_src),
            'version_src=' + ','.join(self.version_src),
            'mp=' + ','.join(self.mp),
            'def=' + ','.join(['='.join(cppdef) for cppdef in self.cpp_defs]),
            'target=' + self.target,
            'prefix=' + self.target_prefix])

        return success == 0



class OLLibrary:
    """OpenLoops library class"""
    def __init__(self, name, target_dir = '', mod_dir = '@mod', mod_dependencies = [], linklibs = [],
                 src_dir = '', mp_src = [], dp_src = [], version_src = [], py_src = [], to_cpp = False):
        self.libname = name
        self.target_dir = target_dir
        if mod_dir == '@mod':
            if src_dir and src_dir != '.':
                self.mod_dir = os.path.join(src_dir, '..', 'mod')
            else:
                self.mod_dir = os.path.join('mod')
        else:
            self.mod_dir = mod_dir
        self.mod_dependencies = list(mod_dependencies)
        self.linklibs = linklibs + [dep.lower() for dep in mod_dependencies]
        self.src = []
        self.add(src_dir = src_dir, mp_src = list(mp_src), dp_src = list(dp_src),
                 version_src = list(version_src), py_src = list(py_src), to_cpp = to_cpp)

    def add(self, src_dir = '', mp_src = [], dp_src = [], version_src = [], py_src = [], to_cpp = False):
        mp_src = [os.path.join(src_dir, src) for src in mp_src]
        dp_src = [os.path.join(src_dir, src) for src in dp_src]
        version_src = [os.path.join(src_dir, src) for src in version_src]
        py_src = [os.path.join(src_dir, src) for src in py_src]
        if to_cpp is False:
            self.src += mp_src + dp_src + version_src + py_src
        else:
            self.src += to_cpp.add(mp_src = mp_src, dp_src = dp_src + py_src, version_src = version_src)

    def compile(self, env, shared = True):

        f_path = env.get('FORTRANPATH', [])
        f90_path = env.get('F90PATH', [])
        if isinstance(f_path, str):
            f_path = [f_path]
        if isinstance(f90_path, str):
            f90_path = [f90_path]
        f_path = f_path + [os.path.join(config['lib_src_dir'], dep, 'mod') for dep in self.mod_dependencies] + [self.mod_dir]
        f90_path = f90_path + [os.path.join(config['lib_src_dir'], dep, 'mod') for dep in self.mod_dependencies] + [self.mod_dir]
        if self.mod_dir and not os.path.isdir(self.mod_dir):
            os.makedirs(self.mod_dir)

        if shared:
            self.lib = env.SharedLibrary(os.path.join(self.target_dir, self.libname.lower()),
                                         self.src,
                                         FORTRANMODDIR = self.mod_dir,
                                         FORTRANPATH = f_path,
                                         F90PATH = f90_path,
                                         LIBS = self.linklibs)
        else:
            self.lib = env.StaticLibrary(os.path.join(self.target_dir, self.libname.lower()),
                                         self.src,
                                         FORTRANMODDIR = self.mod_dir,
                                         FORTRANPATH = f_path,
                                         F90PATH = f90_path,
                                         LIBS = self.linklibs)

        return self.lib
