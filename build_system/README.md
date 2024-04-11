This build system comes from yzziizzy's public domain build system:

https://github.com/yzziizzy/extras_and_rejects/tree/master/build_system
https://notabug.org/yzziizzy/extras_and_rejects

# setup/install
`sudo ln -s /home/username/code/scripts/build_system/mkproject.sh /usr/bin/mkproject`


# basic usage

With existing folder:
```
cd ~/code/
git init new_project
cd new_project
mkproject -x exe_name ./
```

