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
export SMARTCD_HIST_IGNORE=${SMARTCD_HIST_IGNORE:-".git"}	# pipe delimited list of ignored folders

export SMARTCD_CONFIG_FOLDER=${SMARTCD_CONFIG_FOLDER:-"$HOME/.config/smartcd"}
export SMARTCD_HIST_FILE=${SMARTCD_HIST_FILE:-"path_history.db"}
export SMARTCD_AUTOEXEC_FILE=${SMARTCD_AUTOEXEC_FILE:-"autoexec.db"}

# check shell
[ -z "$BASH_VERSION" ] && [ -z "$ZSH_VERSION" ] && printf "Can't use smartcd : unknown shell\n" && return 1

# check if mandatory dependencies are available, otherwise skip replacing built-in cd
[ -z "$( whereis -b fzf | command awk '{ print $2 }' )" ] && printf "Can't use smartcd : missing fzf\n" && return 1
[ -z "$( whereis -b md5sum | command awk '{ print $2 }' )" ] && printf "Can't use smartcd : missing md5sum\n" && return 1

function __smartcd::cd()
{
	local fSearchResults=$( mktemp --tmpdir="/dev/shm/" -t smartcd_$$_XXXXX.tmp )

	local lookUpPath="${1:-$HOME}"	# if no argument is provided, assume $HOME to mimic built-in cd
	local selectedEntry=""
	local fzfSelect1=""

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ] && __smartcd::databaseReset

	if [ "${lookUpPath}" = "-" ] || [ -d "${lookUpPath}" ] ; then

		# dir exists, navigate to it
		selectedEntry="${lookUpPath}"

	elif [ "${lookUpPath}" = "--" ] ; then

		# search in database for historical paths
		__smartcd::databaseSearch > "${fSearchResults}"
		selectedEntry=$( __smartcd::choose "${fSearchResults}" "${fzfSelect1}" )

	else

		# search in database
		__smartcd::databaseSearch "${lookUpPath}" > "${fSearchResults}"

		# trust in database result
		[ $( command wc --lines < "${fSearchResults}" ) -gt 0 ] && fzfSelect1="--select-1"

		# add filesystem results
		__smartcd::filesystemSearch "${lookUpPath}" >> "${fSearchResults}"

		if [ $( command wc --lines < "${fSearchResults}" ) -gt 0 ] ; then

			# found something, offer to select
			selectedEntry=$( __smartcd::choose "${fSearchResults}" "${fzfSelect1}" )

		else

			# otherwise, throw error ( no such file or directory )
			selectedEntry="${lookUpPath}"

		fi
	fi

	command rm --force "${fSearchResults}"
	__smartcd::enterPath "${selectedEntry}"
}

function __smartcd::choose()
{
	local fOptions="${1}"
	local fzfSelect1="${2}"
	local fzfPreview=""
	local cmdPreview=$( whereis -b exa tree ls | command awk '/: ./ { print $2 ; exit }' )
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
	local cmdFinder=$( whereis -b fdfind fd find | command awk '/: ./ { print $2 ; exit }' )

	case "${cmdFinder}" in

	*/fd*)
		"${cmdFinder}" --hidden --no-ignore-vcs "${searchString}" --color=never --follow --min-depth=1 --max-depth=1 --type=directory --exclude ".git/" "${searchPath}" --exec realpath --no-symlink 2>/dev/null
	;;

	*)
		"${cmdFinder}" "${searchPath}" -follow -mindepth 1 -maxdepth 1 -type d ! -path '*\.git/*' -iname '*'"${searchString}"'*' -exec realpath --no-symlinks {} + 2>/dev/null
	;;
	esac
}

function __smartcd::databaseSearch()
{
	local searchString=$( echo "${1}" | sed --expression='s:\.:\\.:g' --expression='s:/:.*/.*:g' )

	# search paths ending with *searchString* ( no deeper paths after searchString allowed )
	command grep --ignore-case --extended-regexp "${searchString}"'[^/]*$' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::databaseSavePath()
{
	local directory="${1}"

	local iCounter=0
	local ignoreItem=""
	local ignoreItemFound=""

	[ "${directory}" = "${HOME}" ] || [ "${directory}" = "/" ] && return	# avoid saving $HOME and /

	# search in ignore list
	while true ; do

		(( ++iCounter ))

		ignoreItem=$( echo "${SMARTCD_HIST_IGNORE}"'|' | command cut --delimiter='|' --fields=${iCounter} )
		[ -z "${ignoreItem}" ] && break

		ignoreItemFound=$( echo "${directory}" | command grep --extended-regexp '/'"${ignoreItem}"'$|/'"${ignoreItem}"'/' )

		if [ ! -z "${ignoreItemFound}" ] ; then
			# remove ignored entry and leave function
			__smartcd::databaseDeletePath "${directory}"
			return
		fi
	done

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

	local fTmp=$( mktemp )
	local line=""

	local iCounter=0
	local bIgnore="false"
	local ignoreItem=""
	local ignoreItemFound=""

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ] && __smartcd::databaseReset

	while read -r line || [ -n "${line}" ] ; do

		if [ -d "${line}" ] ; then

			iCounter=0
			bIgnore="false"

			# search in ignore list
			while true ; do

				(( ++iCounter ))

				ignoreItem=$( echo "${SMARTCD_HIST_IGNORE}"'|' | command cut --delimiter='|' --fields=${iCounter} )
				[ -z "${ignoreItem}" ] && break

				ignoreItemFound=$( echo "${line}" | command grep --extended-regexp '/'"${ignoreItem}"'$|/'"${ignoreItem}"'/' )

				if [ ! -z "${ignoreItemFound}" ] ; then
					bIgnore="true"
					break
				fi
			done

			[ "${bIgnore}" = "false" ] && printf "%s\n" "${line}" >> "${fTmp}"
		fi

	done < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	command awk '!seen[$0]++' "${fTmp}" > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	# remove empty lines
	command sed --in-place '/^[[:blank:]]*$/ d' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	# at least one row needed
	[ $( command wc --lines < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ) -eq 0 ] && __smartcd::databaseReset

	command rm --force "${fTmp}"
}

function __smartcd::databaseReset()
{
	mkdir --parents "${SMARTCD_CONFIG_FOLDER}"
	printf "\n" > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::autoexecRun()
{
	local bExecuted="false"
	local fAutoexec="${1}"
	local checksum=""
	local checksumStored=""

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ] && __smartcd::autoexecReset

	# autoexec file
	if [ -f "${fAutoexec}" ] && [ ! -r "${fAutoexec}" ] ; then

		printf "smartcd - autoexec file [ ${fAutoexec} ] : UNREADABLE\n"

	elif [ -r "${fAutoexec}" ] ; then

		checksum=$( command md5sum "${fAutoexec}" | command awk '{ print $1 }' )
		checksumStored=$( command grep --max-count=1 "${PWD}/${fAutoexec}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command cut --delimiter='|' --fields=2 )

		if [ "${checksum}" = "${checksumStored}" ] ; then
			bExecuted="true"
			source "${fAutoexec}"
		else
			printf "smartcd - autoexec file [ ${fAutoexec} ] : INVALID CHECKSUM\n"
		fi
	fi

	# global autoexec file
	if [ -f "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ] && [ ! -r "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ] ; then

		printf "smartcd - autoexec file [ "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ] : UNREADABLE\n"

	elif [ -r "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ] && [ "${bExecuted}" = "false" ] ; then

		checksum=$( command md5sum "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" | command awk '{ print $1 }' )
		checksumStored=$( command grep --max-count=1 "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command cut --delimiter='|' --fields=2 )

		if [ "${checksum}" = "${checksumStored}" ] ; then
			source "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}"
		else
			printf "smartcd - autoexec file [ "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ] : INVALID CHECKSUM\n"
		fi
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

	printf "${fAutoexec}|${checksum}\n" >> "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
	printf "smartcd - autoexec file [ ${fAutoexec} ] : ADDED\n"

	# remove previous checksum
	__smartcd::autoexecCleanup
}

function __smartcd::autoexecCleanup()
{
	local IFS=

	local fTmp=$( mktemp )
	local line=""
	local fAutoexec=""
	local checksum=""
	local checksumStored=""

	[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ] && __smartcd::autoexecReset

	while read -r line || [ -n "${line}" ] ; do

		fAutoexec=$( echo "${line}" | command cut --delimiter='|' --fields=1 )
		checksumStored=$( echo "${line}" | command cut --delimiter='|' --fields=2 )
		checksum=""

		[ -r "${fAutoexec}" ] && checksum=$( command md5sum "${fAutoexec}" | command awk '{ print $1 }' )

		[ "${checksum}" = "${checksumStored}" ] && printf "%s\n" "${line}" >> "${fTmp}"

	done < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# order file and remove duplicated entries
	command sort --unique "${fTmp}" > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# remove empty lines
	command sed --in-place '/^[[:blank:]]*$/ d' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# at least one row needed
	[ $( command wc --lines < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ) -eq 0 ] && __smartcd::autoexecReset

	command rm --force "${fTmp}"
	command chmod 600 "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
}

function __smartcd::autoexecReset()
{
	mkdir --parents "${SMARTCD_CONFIG_FOLDER}"
	printf "\n" > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
	command chmod 600 "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
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

		*)
			printf "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] : CANCELLED\n"
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

		*)
			printf "smartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] : CANCELLED\n"
		;;
	esac
}

function __smartcd::upgrade()
{
	local readonly SRC_REMOTE="https://raw.githubusercontent.com/lfromanini/smartcd/main/smartcd.sh"

	local returnCode=0
	local answer=""
	local fScriptInstalled=""
	local fScriptRemote=""
	local versionInstalled=$( __smartcd::printVersion | command cut --delimiter=' ' --fields=2 )
	local versionRemote=""

	if [ -n "$BASH_VERSION" ] ; then

		fScriptInstalled=$( dirname "$( realpath ${BASH_SOURCE[0]} )" )

	elif [ -n "$ZSH_VERSION" ] ; then

		fScriptInstalled=${${(%):-%x}:A:h}

	else

		printf "Can't use smartcd : unknown shell\n"
		return 1
	fi

	fScriptInstalled+="/smartcd.sh"

	if [ ! -w "${fScriptInstalled}" ] ; then

		printf "\nsmartcd - can't upgrade read only file [ ${fScriptInstalled} ]\n"
		printf "smartcd - aborting...\n"
		return 1
	fi

	printf "smartcd - downloading remote version...\n\n"
	fScriptRemote=$( mktemp )

	command curl --location --output "${fScriptRemote}" "${SRC_REMOTE}"
	returnCode=$?

	if [ ${returnCode} -ne 0 ] ; then

		command rm --force "${fScriptRemote}"
		printf "smartcd - could not download remote version : FAILED\n"
		return ${returnCode}
	fi

	versionRemote=$( command grep 'local readonly VERSION=' "${fScriptRemote}" | command grep --invert-match 'grep' | command cut --delimiter='"' --fields=2 )

	if [ "${versionInstalled}" = "${versionRemote}" ] ; then

		printf "\nsmartcd - no need to upgrade [ ${versionInstalled} ]\n"
		command rm --force "${fScriptRemote}"
		return 0
	fi

	printf "\nsmartcd - upgrade available [ ${versionInstalled} -> ${versionRemote} ]\n"
	printf '\033[1m'"Upgrade [y/n]? "'\033[22m'
	answer="" ; read answer

	case "${answer}" in
		Y|y|YES|yes|Yes)
			printf "\nsmartcd - upgrading file [ ${fScriptInstalled} ]...\n"
			command mv --force "${fScriptRemote}" "${fScriptInstalled}"
			returnCode=$?

			if [ ${returnCode} -eq 0 ] ; then

				printf "smartcd - upgrade [ ${versionInstalled} -> ${versionRemote} ] : UPGRADED\n"
				source "${fScriptInstalled}"

			else

				command rm --force "${fScriptRemote}"
				printf "smartcd - upgrade [ ${versionInstalled} -> ${versionRemote} ] : FAILED\n"
			fi
		;;

		*)
			command rm --force "${fScriptRemote}"
			printf "\nsmartcd - upgrade [ ${versionInstalled} -> ${versionRemote} ] : CANCELLED\n"
		;;
	esac

	return ${returnCode}
}

function __smartcd::printVersion()
{
	local readonly VERSION="2.4.4"
	printf "smartcd ${VERSION}\n"
}

function __smartcd::printHelp()
{
	__smartcd::printVersion
	printf "A mnemonist cd command with autoexec feature\n\n"
	printf "Options:\n\n"
	printf "smartcd [OPTIONS]\n\n"
	printf "    -l, --list                list paths saved at database file and allowed autexec files\n"
	printf "                              also print ignored paths list\n\n"
	printf "    -c, --cleanup             remove incorrect entries from paths and autoexec database files\n\n"
	printf "    -e, --edit                manually edit paths database file\n"
	printf "                              autoexec database file should not be manually edited\n\n"
	printf "    -r, --reset               reset database file to original state\n\n"
	printf "        --autoexec=\"[FILE]\"   for security reasons, authorize file to be autoexecuted\n"
	printf "                              if FILE contents changes, it must be authorized again\n"
	printf "                              FILE can be relative to folder:\n"
	printf "                                  /path/to/.on_entry.smartcd.sh\n"
	printf "                                  /path/to/.on_leave.smartcd.sh\n"
	printf "                              or global ( wihout the \".\" at filename ):\n"
	printf "                                  ${SMARTCD_CONFIG_FOLDER}/on_entry.smartcd.sh\n"
	printf "                                  ${SMARTCD_CONFIG_FOLDER}/on_leave.smartcd.sh\n"
	printf "                              ( if relative file is executed, global will be skipped for the given folder )\n\n"
	printf "    -u, --upgrade             self upgrade if a new version is available online\n\n"
	printf "    -v, --version             output version information\n\n"
	printf "    -h, --help                display this help\n\n"
	printf "cd [ARGS]\n\n"
	printf "        --                    list last directories and navigate to the selected entry\n\n"
	printf "        [STRING]              searchs in filesystem and in database file for partial matches\n\n"
	printf "Databases:\n\n"
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
				command grep --color=auto --line-number "" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" 2>/dev/null
				printf "\nsmartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] contents:\n\n"
				{ command cut --delimiter='|' --fields="1" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command grep --color=auto --line-number --extended-regexp 'on_entry|on_leave' ; } 2>/dev/null
				printf "\nsmartcd - ignore list [ \$SMARTCD_HIST_IGNORE ] sorted contents:\n"
				printf "          ( always ignored \"/\" and \"\$HOME\" )\n\n"
				printf "${SMARTCD_HIST_IGNORE}""\n" | command sed 's:|:'"\n"':g' | command sort --unique
			;;

			-c|--cleanup)
				__smartcd::databaseCleanup
				printf "smartcd - paths database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE} ] : CLEAR\n"
				__smartcd::autoexecCleanup
				printf "smartcd - autoexec database file [ ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE} ] : CLEAR\n"
			;;

			-e|--edit)
				if [ ! -z "${EDITOR}" ] ; then
					"${EDITOR}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
					# at least one row needed
					[ $( command wc --lines < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ) -eq 0 ] && __smartcd::databaseReset || true
				else
					printf "smartcd - editor variable not set [ \$EDITOR ] : ABORTED\n"
				fi
			;;

			-r|--reset)
				__smartcd::askAndReset
			;;

			--autoexec=*)
				fAutoexec="${arg#*=}"
				__smartcd::autoexecAdd "${fAutoexec}"
			;;

			-u|--upgrade)
				__smartcd::upgrade
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
