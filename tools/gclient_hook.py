# Copyright (c) 2011 The Chromium Embedded Framework Authors.
# Portions copyright (c) 2006-2008 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

from gclient_util import *
import os, sys

# The CEF root directory is the parent directory of _this_ script.
cef_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))

print "\nPatching build configuration and source files for CEF..."
patcher = [ 'python', 'tools/patcher.py', 
            '--patch-config', 'patch/patch.cfg' ];
RunAction(cef_dir, patcher);

print "\nGenerating CEF project files..."
os.environ['CEF_DIRECTORY'] = os.path.basename(cef_dir);
gyper = [ 'python', 'tools/gyp_cef', 'cef.gyp', '-I', 'cef.gypi' ]
RunAction(cef_dir, gyper);
