# https://github.com/lfromanini/smartcd
#
# A cd command with improved usability features
#
# examples:
#
# resolve directory name with case insensitive :
# cd incompleteFolderNam
#
# list last directories and navigate to the selected entry
# cd --
#
# some aliases :
#
# -     ( return to previous folder, like "cd -" )
# cd..  ( cd .. )
# ..    ( cd .. )
# ..2   ( cd ../.. )
# ..3   ( cd ../../.. )
#
# execute files .on_enter.smartcd.sh and .on_leave.smartcd.sh if available

export SMARTCD_HIST_SIZE=${SMARTCD_HIST_SIZE:-"100"}

export SMARTCD_CONFIG_FOLDER=${SMARTCD_CONFIG_FOLDER:-"$HOME/.config/smartcd"}
export SMARTCD_HIST_FILE=${SMARTCD_HIST_FILE:-"path_history.db"}
export SMARTCD_AUTOEXEC_FILE=${SMARTCD_AUTOEXEC_FILE:-"autoexec.db"}

function __smartcd::cd()
{
	local readonly SMARTCD_SEARCH_RESULTS="/dev/shm/smartcd_pid_$$.db.tmp"

	local lookUpPath="${1}"
	local selectedEntry=""
	local fzfSelect1=""

	# create database files if not exists
	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ] && __smartcd::databaseReset
	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ] && __smartcd::autoexecReset

	# if no argument is provided, assume $HOME to mimic built-in cd
	[ -z "${lookUpPath}" ] && lookUpPath="$HOME"

	if [ "${lookUpPath}" = "-" ] || [ -d "${lookUpPath}" ] ; then

		# dir exists, navigate to it
		selectedEntry="${lookUpPath}"

	elif [ "${lookUpPath}" = "--" ] ; then

		# search in database for historical paths
		__smartcd::databaseSearch > "${SMARTCD_SEARCH_RESULTS}"
		selectedEntry=$( __smartcd::choose "${SMARTCD_SEARCH_RESULTS}" "${fzfSelect1}" )

	else

		# search in database
		__smartcd::databaseSearch "${lookUpPath}" > "${SMARTCD_SEARCH_RESULTS}"

		# trust in database result
		[ $( command wc --lines < "${SMARTCD_SEARCH_RESULTS}" ) -gt 0 ] && fzfSelect1="--select-1"

		# add filesystem results
		__smartcd::filesystemSearch "${lookUpPath}" >> "${SMARTCD_SEARCH_RESULTS}"

		if [ $( command wc --lines < "${SMARTCD_SEARCH_RESULTS}" ) -gt 0 ] ; then

			# found something, offer to select
			selectedEntry=$( __smartcd::choose "${SMARTCD_SEARCH_RESULTS}" "${fzfSelect1}" )

		else

			# otherwise, throw error ( no such file or directory )
			selectedEntry="${lookUpPath}"

		fi
	fi

	[ -f "${SMARTCD_SEARCH_RESULTS}" ] && rm -f "${SMARTCD_SEARCH_RESULTS}"
	__smartcd::enterPath "${selectedEntry}"
}

function __smartcd::choose()
{
	local fOptions="${1}"
	local fzfSelect1="${2}"
	local fzfPreview=""
	local cmdPreview=$( whereis -b exa tree ls | command awk '{ print $2 }' | command awk '/./ { print ; exit }' )
	local errMessage="no such directory [ {} ]'\n\n'hint: run '\033[1m'smartcd --cleanup'\033[22m'"

	if [[ "${cmdPreview}" = */exa ]] ; then

		fzfPreview='[ -d {} ] && '${cmdPreview}' --tree --colour=always --icons --group-directories-first --all --level=1 {} || echo '"${errMessage}"''

	elif [[ "${cmdPreview}" = */tree ]] ; then

		fzfPreview='[ -d {} ] && '${cmdPreview}' --dirsfirst -a -x -C --filelimit 100 -L 1 {} || echo '"${errMessage}"''

	else

		fzfPreview='[ -d {} ] && echo [ {} ] ; '${cmdPreview}' --color=always --almost-all --group-directories-first {} || echo '"${errMessage}"''

	fi

	command awk '!seen[$0]++' "${fOptions}" | command fzf ${fzfSelect1} --delimiter="\n" --layout="reverse" --height="40%" --preview="${fzfPreview}"
}

function __smartcd::enterPath()
{
	local returnCode=0
	local directory="${1}"

	[ "${PWD}" = "${directory}" ] && return ${returnCode}

	if [ -d "${directory}" ] && [ -r "${directory}" ] || [ "-" = "${directory}" ] ; then
		__smartcd::autoexecRun .on_leave.smartcd.sh
	fi

	builtin cd "${directory}"
	returnCode=$?

	if [ ${returnCode} -eq 0 ] ; then

		__smartcd::databaseSavePath "${PWD}"
		__smartcd::autoexecRun .on_entry.smartcd.sh

	else
		__smartcd::databaseDeletePath "${directory}"
	fi

	return ${returnCode}
}

function __smartcd::filesystemSearch()
{
	local searchPath=$( dirname -- "${1}" )
	local searchString=$( basename -- "${1}" )
	local cmdFinder=$( whereis -b fdfind fd find | command awk '{ print $2 }' | command awk '/./ { print ; exit }' )

	if [[ "${cmdFinder}" = */fd* ]] ; then

		"${cmdFinder}" --hidden "${searchString}" --color=never --follow --min-depth=1 --max-depth=1 --type=directory --exclude ".git/" "${searchPath}" --exec realpath --no-symlink 2>/dev/null

	else

		"${cmdFinder}" "${searchPath}" -follow -mindepth 1 -maxdepth 1 -type d ! -path '*\.git/*' -iname '*'"${searchString}"'*' -exec realpath --no-symlinks {} + 2>/dev/null

		# ordered by lowest depth
#		"${cmdFinder}" "${searchPath}" -follow -mindepth 1 -maxdepth 1 -type d ! -path '*\.git/*' -iname '*'"${searchString}"'*' -printf '%d "%p"\n' 2>/dev/null \
#			| command sort --numeric-sort | command cut --delimiter=' ' --fields="2-" | xargs realpath --no-symlinks 2>/dev/null

	fi
}

function __smartcd::databaseSearch()
{
	local searchString=$( echo "${1}" | command sed --expression='s:\.:\\.:g' --expression='s:/:.*/.*:g' )

	# search paths ending with *searchString* ( no deeper paths after searchString allowed )
	command grep --ignore-case --extended-regexp "${searchString}"'[^/]*$' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::databaseSavePath()
{
	local directory="${1}"

	[ "${directory}" = "${HOME}" ] || [ "${directory}" = "/" ] && return	# avoid saving $HOME and /

	# remove previous entry
	__smartcd::databaseDeletePath "${directory}"

	# add to first row
	command sed --in-place "1 s:^:${directory}\n:" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	# limit max records
	command sed --in-place $(( ${SMARTCD_HIST_SIZE} + 1 ))',$ d' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::databaseDeletePath()
{
	local directory="${1}"
	command sed --in-place "\\:^${directory}$:d" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::databaseCleanup()
{
	local IFS=

	local fTmp=$( mktemp --tmpdir="/dev/shm/" )
	local line=""

	while read -r line || [ -n "${line}" ] ; do

		[ -d "${line}" ] && printf "%s\n" "${line}" >> "${fTmp}"

	done < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	command awk '!seen[$0]++' "${fTmp}" > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	# remove empty lines
	command sed --in-place '/^[[:blank:]]*$/ d' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	# at least one row needed
	[ $( command wc --lines < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ) -eq 0 ] && echo > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	rm -f "${fTmp}"
}

function __smartcd::databaseReset()
{
	mkdir --parents "${SMARTCD_CONFIG_FOLDER}"
	echo > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::autoexecRun()
{
	local bExecuted="false"
	local fAutoexec="${1}"
	local checksum=""
	local checksumStored=""

	if [ -r "${fAutoexec}" ] ; then

		# autoexec file
		checksum=$( command md5sum "${fAutoexec}" | command awk '{ print $1 }' )
		checksumStored=$( command grep "${PWD}/${fAutoexec}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command cut --delimiter='|' --fields="2" )
		[ "${checksum}" = "${checksumStored}" ] && bExecuted="true" && source "${fAutoexec}"

	fi

	if [ "${bExecuted}" = "false" ] && [ -r "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ] ; then

		# global autoexec file
		checksum=$( command md5sum "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" | command awk '{ print $1 }' )
		checksumStored=$( command grep "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command cut --delimiter='|' --fields="2" )
		[ "${checksum}" = "${checksumStored}" ] && source "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}"

	fi
}

function __smartcd::autoexecAdd()
{
	local fAutoexec=$( realpath "${1}" )
	local fPath=$( dirname -- "${fAutoexec}" )
	local fName=$( basename -- "${fAutoexec}" )
	local checksum=""

	if [ "${fPath}" = "${SMARTCD_CONFIG_FOLDER}" ] && [ "${fName}" != "on_entry.smartcd.sh" ] && [ "${fName}" != "on_leave.smartcd.sh" ] ; then

		echo "smartcd - autoexec file [ ${fAutoexec} ] : INVALID FILENAME"
		return 2

	elif [ "${fPath}" != "${SMARTCD_CONFIG_FOLDER}" ] && [ "${fName}" != ".on_entry.smartcd.sh" ] && [ "${fName}" != ".on_leave.smartcd.sh" ] ; then

		echo "smartcd - autoexec file [ ${fAutoexec} ] : INVALID FILENAME"
		return 2

	elif [ ! -r "${fAutoexec}" ] ; then

		echo "smartcd - autoexec file [ ${fAutoexec} ] : UNREADABLE"
		return 2

	fi

	checksum=$( command md5sum "${fAutoexec}" | command awk '{ print $1 }' )

	echo "${fAutoexec}""|""${checksum}" >> "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
	echo "smartcd - autoexec file [ ${fAutoexec} ] : ADDED"

	# remove previous checksum
	__smartcd::autoexecCleanup
}

function __smartcd::autoexecCleanup()
{
	local IFS=

	local fTmp=$( mktemp --tmpdir="/dev/shm/" )
	local line=""
	local fAutoexec=""
	local checksum=""
	local checksumStored=""

	while read -r line || [ -n "${line}" ] ; do

		fAutoexec=$( echo "${line}" | command cut --delimiter='|' --fields="1" )
		checksumStored=$( echo "${line}" | command cut --delimiter='|' --fields="2" )
		checksum=""

		[ -r "${fAutoexec}" ] && checksum=$( command md5sum "${fAutoexec}" | command awk '{ print $1 }' )

		[ "${checksum}" = "${checksumStored}" ] && printf "%s\n" "${line}" >> "${fTmp}"

	done < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# order file and remove duplicated entries
	command sort --unique "${fTmp}" > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# remove empty lines
	command sed --in-place '/^[[:blank:]]*$/ d' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# at least one row needed
	[ $( command wc --lines < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ) -eq 0 ] && echo > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	rm -f "${fTmp}"
}

function __smartcd::autoexecReset()
{
	mkdir --parents "${SMARTCD_CONFIG_FOLDER}"
	echo > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
}

function smartcd()
{
	local readonly VERSION="2.2.0"
	local arg=""
	local fAutoexec=""

	[ -z "${1}" ] && 1="--help"

	for arg in "$@" ; do

		case "${arg}" in
			-l|--list)
				echo "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] contents:"
				echo
				command grep --color=auto --line-number "" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
				echo
				echo "smartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] contents:"
				echo
				command cut --delimiter='|' --fields="1" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command grep --color=auto --line-number --extended-regexp 'on_entry|on_leave'
			;;

			-c|--cleanup)
				__smartcd::databaseCleanup
				echo "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] : CLEAR"
				__smartcd::autoexecCleanup
				echo "smartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] : CLEAR"
			;;

			-r|--reset)
				__smartcd::databaseReset
				echo "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] : RESET"
				__smartcd::autoexecReset
				echo "smartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] : RESET"
			;;

			--autoexec=*)
				fAutoexec="${arg#*=}"
				__smartcd::autoexecAdd "${fAutoexec}"
			;;

			-v|--version)
				echo "smartcd ${VERSION}"
				return 0
			;;

			-h|--help)
				echo "smartcd ${VERSION}"
				echo "A mnemonist cd command with autoexec feature"
				echo
				echo "Usage:"
				echo "    smartcd [OPTIONS]"
				echo
				echo "    -l, --list            list paths saved at database file and allowed autexec files"
				echo
				echo "    -c, --cleanup         remove incorrect entries from paths and autoexec database files"
				echo
				echo "    -r, --reset           reset database file to original state"
				echo
				echo "    --autoexec=\"[FILE]\"   for security reasons, authorize file to be autoexecuted"
				echo "                          if FILE contents changes, it must be authorized again"
				echo "                          FILE can be relative to folder:"
				echo "                              /path/to/.on_entry.smartcd.sh"
				echo "                              /path/to/.on_leave.smartcd.sh"
				echo "                          or global ( wihout the \".\" at filename ):"
				echo "                              ${SMARTCD_CONFIG_FOLDER}/on_entry.smartcd.sh"
				echo "                              ${SMARTCD_CONFIG_FOLDER}/on_leave.smartcd.sh"
				echo "                          ( if relative file is executed, global will be skipped for the given folder )"
				echo
				echo "    -v, --version         output version information"
				echo
				echo "    -h, --help            display this help"
				echo
				echo "    cd [ARGS]"
				echo
				echo "    --                    list last directories and navigate to the selected entry"
				echo "    [STRING]              searchs in filesystem and in database file for partial matches"
				echo
				echo "Databases:"
				echo "    ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
				echo "    ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
				return 0
			;;

			*)
				echo "error: Found argument \"${arg}\" which wasn't expected. Try --help"
				return 1
			;;
		esac
	done
}

# check if mandatory dependencies are available, otherwise skip replacing built-in cd
[ -z "$( whereis -b fzf | command awk '{ print $2 }' )" ] && echo "Can't use smartcd : missing fzf" && return 1
[ -z "$( whereis -b md5sum | command awk '{ print $2 }' )" ] && echo "Can't use smartcd : missing md5sum" && return 1

# bash builtin cd case insensitive
#[ -n "$BASH_VERSION" ] && shopt -s cdspell

# key bindings
[ -n "$BASH_VERSION" ] && bind '"\C-g":"cd --\n"'
[ -n "$ZSH_VERSION" ] && bindkey -s '^g' 'cd --\n'

# aliases
alias cd="__smartcd::cd"
alias -- -="cd -"
alias cd..="cd .."
alias ..="cd .."
alias ..2="cd ../.."
alias ..3="cd ../../.."
