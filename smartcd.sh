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

	local lookUpPath="${1:-$HOME}"	# if no argument is provided, assume $HOME to mimic built-in cd
	local selectedEntry=""
	local fzfSelect1=""

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ] && __smartcd::databaseReset

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

	case "${cmdPreview}" in

	*/exa)
		fzfPreview='[ -d {} ] && '${cmdPreview}' --tree --colour=always --icons --group-directories-first --all --level=1 {} || echo '"${errMessage}"''
	;;

	*/tree)
		fzfPreview='[ -d {} ] && '${cmdPreview}' --dirsfirst -a -x -C --filelimit 100 -L 1 {} || echo '"${errMessage}"''
	;;

	*)
		fzfPreview='[ -d {} ] && echo [ {} ] ; '${cmdPreview}' --color=always --almost-all --group-directories-first {} || echo '"${errMessage}"''
	;;

	esac

	command awk '!seen[ $0 ]++ && $0 != ""' "${fOptions}" | command fzf ${fzfSelect1} --delimiter="\n" --layout="reverse" --height="40%" --preview="${fzfPreview}"
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

	case "${cmdFinder}" in

	*/fd*)
		"${cmdFinder}" --hidden "${searchString}" --color=never --follow --min-depth=1 --max-depth=1 --type=directory --exclude ".git/" "${searchPath}" --exec realpath --no-symlink 2>/dev/null
	;;

	*)
		"${cmdFinder}" "${searchPath}" -follow -mindepth 1 -maxdepth 1 -type d ! -path '*\.git/*' -iname '*'"${searchString}"'*' -exec realpath --no-symlinks {} + 2>/dev/null
	;;

	esac
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

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ] && __smartcd::databaseReset

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

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ] && __smartcd::autoexecReset

	if [ -r "${fAutoexec}" ] ; then

		# autoexec file
		checksum=$( command md5sum "${fAutoexec}" | command awk '{ print $1 }' )
		checksumStored=$( command grep --max-count=1 "${PWD}/${fAutoexec}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command cut --delimiter='|' --fields="2" )
		[ "${checksum}" = "${checksumStored}" ] && bExecuted="true" && source "${fAutoexec}"

	fi

	if [ "${bExecuted}" = "false" ] && [ -r "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ] ; then

		# global autoexec file
		checksum=$( command md5sum "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" | command awk '{ print $1 }' )
		checksumStored=$( command grep --max-count=1 "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command cut --delimiter='|' --fields="2" )
		[ "${checksum}" = "${checksumStored}" ] && source "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}"

	fi
}

function __smartcd::autoexecAdd()
{
	local fAutoexec=$( realpath -- "${1}" )
	local fPath=$( dirname -- "${fAutoexec}" )
	local fName=$( basename -- "${fAutoexec}" )
	local checksum=""

	if [ "${fPath}" = "${SMARTCD_CONFIG_FOLDER}" ] && [ "${fName}" != "on_entry.smartcd.sh" ] && [ "${fName}" != "on_leave.smartcd.sh" ] ; then

		printf "smartcd - autoexec file [ ${fAutoexec} ] : INVALID FILENAME\n"
		return 2

	elif [ "${fPath}" != "${SMARTCD_CONFIG_FOLDER}" ] && [ "${fName}" != ".on_entry.smartcd.sh" ] && [ "${fName}" != ".on_leave.smartcd.sh" ] ; then

		printf "smartcd - autoexec file [ ${fAutoexec} ] : INVALID FILENAME\n"
		return 2

	elif [ ! -r "${fAutoexec}" ] ; then

		printf "smartcd - autoexec file [ ${fAutoexec} ] : UNREADABLE\n"
		return 2

	fi

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ] && __smartcd::autoexecReset

	checksum=$( command md5sum "${fAutoexec}" | command awk '{ print $1 }' )

	echo "${fAutoexec}""|""${checksum}" >> "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
	printf "smartcd - autoexec file [ ${fAutoexec} ] : ADDED\n"

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

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ] && __smartcd::autoexecReset

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

function __smartcd::askAndReset()
{
	local answer=""

	printf "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] will be erased\n"
	printf '\033[1m'"Continue [y/n]? "'\033[22m'
	answer="" ; read answer

	case "${answer}" in
		Y|y|YES|yes|Yes)
			__smartcd::databaseReset
			printf "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] : RESET\n"
		;;
	esac

	printf "\nsmartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] will be erased\n"
	printf '\033[1m'"Continue [y/n]? "'\033[22m'
	answer="" ; read answer

	case "${answer}" in
		Y|y|YES|yes|Yes)
			__smartcd::autoexecReset
			printf "smartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] : RESET\n"
		;;
	esac
}

function __smartcd::printVersion()
{
	local readonly VERSION="2.2.2"
	printf "smartcd ${VERSION}\n"
}

function __smartcd::printHelp()
{
	__smartcd::printVersion

	printf "A mnemonist cd command with autoexec feature\n\n"
	printf "Usage:\n"
	printf "    smartcd [OPTIONS]\n\n"
	printf "    -l, --list            list paths saved at database file and allowed autexec files\n\n"
	printf "    -c, --cleanup         remove incorrect entries from paths and autoexec database files\n\n"
	printf "    -r, --reset           reset database file to original state\n\n"
	printf "    --autoexec=\"[FILE]\"   for security reasons, authorize file to be autoexecuted\n"
	printf "                          if FILE contents changes, it must be authorized again\n"
	printf "                          FILE can be relative to folder:\n"
	printf "                              /path/to/.on_entry.smartcd.sh\n"
	printf "                              /path/to/.on_leave.smartcd.sh\n"
	printf "                          or global ( wihout the \".\" at filename ):\n"
	printf "                              ${SMARTCD_CONFIG_FOLDER}/on_entry.smartcd.sh\n"
	printf "                              ${SMARTCD_CONFIG_FOLDER}/on_leave.smartcd.sh\n"
	printf "                          ( if relative file is executed, global will be skipped for the given folder )\n\n"
	printf "    -v, --version         output version information\n\n"
	printf "    -h, --help            display this help\n\n"
	printf "    cd [ARGS]\n\n"
	printf "    --                    list last directories and navigate to the selected entry\n"
	printf "    [STRING]              searchs in filesystem and in database file for partial matches\n\n"
	printf "Databases:\n"
	printf "    ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}\n"
	printf "    ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}\n"
}

function smartcd()
{
	local arg=""
	local fAutoexec=""

	[ -z "${1}" ] && 1="--help"

	for arg in "$@" ; do

		case "${arg}" in
			-l|--list)
				printf "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] contents:\n\n"
				command grep --color=auto --line-number "" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" 2>/dev/null || true
				printf "\nsmartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] contents:\n\n"
				{ command cut --delimiter='|' --fields="1" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command grep --color=auto --line-number --extended-regexp 'on_entry|on_leave' ; } 2>/dev/null || true
			;;

			-c|--cleanup)
				__smartcd::databaseCleanup
				printf "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] : CLEAR\n"
				__smartcd::autoexecCleanup
				printf "smartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] : CLEAR\n"
			;;

			-r|--reset)
				__smartcd::askAndReset
			;;

			--autoexec=*)
				fAutoexec="${arg#*=}"
				__smartcd::autoexecAdd "${fAutoexec}"
			;;

			-v|--version)
				__smartcd::printVersion
				return 0
			;;

			-h|--help)
				__smartcd::printHelp
				return 0
			;;

			*)
				printf "error: Found argument \"${arg}\" which wasn't expected. Try --help\n"
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
