#!/bin/bash


for module in $(ls -d aur-pkgs/*/); do
    echo "Removing module $module"
    git submodule deinit -f "$module"
    git rm -f "$module"
    rm -rf "$module"
done

