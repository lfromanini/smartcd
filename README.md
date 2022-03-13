<img align="right" src="https://cdn.rawgit.com/sindresorhus/awesome/d7305f38d29fed78fa85652e3a63e154dd8e8829/media/badge.svg">

# smartcd
smartcd - A mnemonist cd command with autoexec feature

```
                          _          _
 ___ _ __ ___   __ _ _ __| |_ ___ __| |
/ __| '_ ` _ \ / _` | '__| __/ __/ _` |
\__ \ | | | | | (_| | |  | || (_| (_| |
|___/_| |_| |_|\__,_|_|   \__\___\__,_|

```

## Description

A `cd` command with improved usability features, which can remember your recently visited directory paths, search and directly traverse to sub-directories, all with fuzzy searching.
This project came to life after I reviewed one initiative at Reddit. At that time I suggested some [changes](https://www.reddit.com/r/commandline/comments/r3ea3b/smartcd_a_mnemonist_cd_command_updated/) but the code author already had improved his initial commit. That's the why I uploaded this version here.

## Usage

This tool saves the last visited and valid directories in `~/.config/smartcd/path_history.db`. If `cd --` is called, **smartcd** will provide an interative search in `~/.config/smartcd/path_history.db`. If `exa` or `tree` (both optional) are available, they will be used as a side panel presenting a preview of the selected directory.

![cd --](https://github.com/lfromanini/smartcd/blob/main/screenshots/cd--.png?raw=true)

If `cd` is called with partial (case insensitive) folder name, **smartcd** will try the best options in filesystem and in the database file. For faster search on filesystem, `fd` will be used, fallbacking to [find](https://linux.die.net/man/1/find) if `fd` is not installed.

Besides of helping navigating paths, `smartcd` comes bundled with an additional feature. If exists a file called `.on_entry.smartcd.sh` or `.on_leave.smartcd.sh`, if will execute it contents at entering or leaving the given folder. For example in a python project folder, create the files as below:

```bash
# on entry
echo "source .venv/bin/activate" > .on_entry.smartcd.sh
smarcd --autoexec=".on_entry.smartcd.sh"
```

```bash
# on leave
echo "deactivate" > .on_leave.smartcd.sh
smarcd --autoexec=".on_leave.smartcd.sh"
```

And `smartcd` will activate and deactivate the virtual environment as soon as it enters or leaves the project folder.

To avoid potential security breachs, autoexecution must be granted with `smartcd --autoexec="[FILE]"`. If file was changed after this command, it must be executed again, otherwise, file will not be executed. To stop autoexecution, just remove the file or rename it.

It is also possible to define and allow global `on_entry` and `on_leave` files. They will be executed only if no custom files are registred in the given folder. Please, notice that those global files **doesn't** starts with **"." (dot)**.

```bash
# on entry
echo "ls -l" > "${SMARTCD_CONFIG_FOLDER}/on_entry.smartcd.sh"
smarcd --autoexec="${SMARTCD_CONFIG_FOLDER}/on_entry.smartcd.sh"
```

```bash
# on leave
echo "echo \"Bye, bye\"" > "${SMARTCD_CONFIG_FOLDER}/on_leave.smartcd.sh"
smarcd --autoexec="${SMARTCD_CONFIG_FOLDER}/on_leave.smartcd.sh"
```

### Shortcuts

Command `cd --` is mapped to `CTRL + g` in BASH and ZSH. Also, the following alias are defined:

```bash
-     # return to previous folder, like "cd -"
cd..  # cd ..
..    # cd ..
..2   # cd ../..
..3   # cd ../../..
```

## Installation

### Bash and Zsh

1. Get it:

Download the file named `smartcd.sh`.

```bash
curl -O https://raw.githubusercontent.com/lfromanini/smartcd/main/smartcd.sh
```

2. Include it:

Then source the file in your `~/.bashrc` and/or `~/.zshrc`:

```bash
$EDITOR ~/.bashrc
# and/or
$EDITOR ~/.zshrc
```

```diff
( ... )
+ source path/to/smartcd.sh
( ... )
```

Finally, reload your configurations.

```bash
source ~/.bashrc
# or
source ~/.zshrc
```

3. Navigate to some paths and don't forget to try `cd --`!

4. Done!

## Configuration

A directory record will be saved by default at `~/.config/smartcd/path_history.db`. This can be overwritten defining `SMARTCD_CONFIG_FOLDER` and `SMARTCD_HIST_FILE` variables before sourcering the code.
Additionally, it's possible to define the maximum entries remembered overwriting `SMARTCD_HIST_SIZE`. Initially, this value is set to 100.
Autoexec database record will be saved in `SMARTCD_CONFIG_FOLDER`.

```bash
( ... )
SMARTCD_CONFIG_FOLDER="$HOME/myConfigFolder"
SMARTCD_HIST_FILE="myConfigFile.db"
SMARTCD_HIST_SIZE="200"
SMARTCD_AUTOEXEC_FILE="myAutoexec.db"

source path/to/smartcd.sh
( ... )
```

## Maintenance

List database file contents:

```bash
smartcd --list
```

Remove all invalid paths from database file (for the case when directory doesn't exists anymore) as also cleanups autoexec database:

```bash
smartcd --cleanup
```

Be careful! This command removes all saved paths and autoexec granted files:

```bash
smartcd --reset
```

Other valid entries are `--version` and `--help`.

#### Requirements

* [fzf](https://github.com/junegunn/fzf)
* [md5sum](https://linux.die.net/man/1/md5sum)
* A not so old Linux distribuition. Since 2.6 Linux kernel builds have started to offer `/dev/shm/` as shared memory in the form of a ramdisk. This `/dev/shm/` is used by **smartcd** for an even better performance.

#### Optional Requirements

* [exa](https://the.exa.website/) : Directory preview. **The icon characters must be present in the font you are using in your terminal** - it is the font that contains the icons. The majority of fonts probably not include these glyphs by default. A good solution to this problem is the [Nerd Fonts project](https://www.nerdfonts.com), which patches existing fixed-width fonts with the necessary icons.
* [tree](https://linux.die.net/man/1/tree) : Directory preview, in case `exa` is not installed.
* [fd](https://github.com/sharkdp/fd) : `find` alternative to search entries in filesystem.

## LICENSE

The [MIT License](https://github.com/lfromanini/smartcd/blob/main/LICENSE) (MIT)
