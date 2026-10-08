export SMARTCD_HIST_SIZE=${SMARTCD_HIST_SIZE:-"100"}
export SMARTCD_HIST_IGNORE=${SMARTCD_HIST_IGNORE:-".git"}								# pipe delimited list of ignored folders

export SMARTCD_CONFIG_FOLDER=${SMARTCD_CONFIG_FOLDER:-"${HOME}/.config/smartcd"}
export SMARTCD_HIST_FILE=${SMARTCD_HIST_FILE:-"path_history.db"}
export SMARTCD_AUTOEXEC_FILE=${SMARTCD_AUTOEXEC_FILE:-"autoexec.db"}

# check shell
[[ -z "${BASH_VERSION}" ]] && [[ -z "${ZSH_VERSION}" ]] && printf "Can't use smartcd : unknown shell\n" && return 1

# check if mandatory dependencies are available, otherwise skip replacing built-in cd
[[ -z "$( whereis -b fzf | awk '{ print $2 }' )" ]] && printf "Can't use smartcd : missing fzf\n" && return 1
[[ -z "$( whereis -b md5sum | awk '{ print $2 }' )" ]] && printf "Can't use smartcd : missing md5sum\n" && return 1

function __smartcd::cd()
{
	local fSearchResults=""

	local lookUpPath="${1:-${HOME}}"													# if no argument is provided, assume $HOME to mimic built-in cd
	local selectedEntry=""
	local fzfSelect1=""

	fSearchResults=$( mktemp --tmpdir="/dev/shm/" -t smartcd_$$_XXXXX.tmp )

	[[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ]] && __smartcd::databaseReset

	if [[ "${lookUpPath}" == "-" ]] || [[ -d "${lookUpPath}" ]] ; then

		selectedEntry="${lookUpPath}"													# dir exists, navigate to it

	elif [[ "${lookUpPath}" == "--" ]] ; then

		__smartcd::databaseSearch > "${fSearchResults}"									# search in database for historical paths
		selectedEntry=$( __smartcd::choose "${fSearchResults}" "${fzfSelect1}" )
	else

		__smartcd::databaseSearch "${lookUpPath}" > "${fSearchResults}"					# search in database
		(( $( wc --lines < "${fSearchResults}" ) > 0 )) && fzfSelect1="--select-1"		# trust in database result
		__smartcd::filesystemSearch "${lookUpPath}" >> "${fSearchResults}"				# add filesystem results

		if (( $( wc --lines < "${fSearchResults}" ) > 0 )) ; then

			selectedEntry=$( __smartcd::choose "${fSearchResults}" "${fzfSelect1}" )	# found something, offer to select
		else

			selectedEntry="${lookUpPath}"												# otherwise, throw error ( no such file or directory )
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
	local cmdPreview=""
	local errMessage="no such directory [ {} ]'\n\n'hint: run '\033[1m'smartcd --cleanup'\033[22m'"

	cmdPreview=$( whereis -b eza exa tree ls | awk '/: ./ { print $2 ; exit }' )

	case "${cmdPreview}" in

	*/exa|*/eza)
		fzfPreview='[ -d {} ] && '${cmdPreview}' --tree --icons --group-directories-first --all --level=1 {} || echo '"${errMessage}"''
	;;

	*/tree)
		fzfPreview='[ -d {} ] && '${cmdPreview}' --dirsfirst -a -x -C --filelimit 100 -L 1 {} || echo '"${errMessage}"''
	;;

	*)
		fzfPreview='[ -d {} ] && echo [ {} ] ; '${cmdPreview}' --color=always --almost-all --group-directories-first {} || echo '"${errMessage}"''
	;;
	esac

	# shellcheck disable=SC2086															# SC2086: Double quote to prevent globbing and word splitting.
	awk '!seen[ $0 ]++ && $0 != ""' "${fOptions}" | fzf ${fzfSelect1} --delimiter="\n" --layout="reverse" --height="40%" --preview="${fzfPreview}"
}

function __smartcd::enterPath()
{
	local returnCode=0
	local directory="${1}"

	[[ "${PWD}" == "${directory}" ]] && return ${returnCode}

	if [[ -d "${directory}" ]] && [[ -r "${directory}" ]] || [[ "-" == "${directory}" ]] ; then
		__smartcd::autoexecRun .on_leave.smartcd.sh
	fi

	builtin cd "${directory}" || returnCode=$?

	if (( returnCode == 0 )) ; then

		__smartcd::databaseSavePath "${PWD}"
		__smartcd::autoexecRun .on_entry.smartcd.sh

	else
		__smartcd::databaseDeletePath "${directory}"
	fi

	return ${returnCode}
}

function __smartcd::filesystemSearch()
{
	local searchPath=""
	local searchString=""
	local cmdFinder=""

	searchPath=$( dirname -- "${1}" )
	searchString=$( basename -- "${1}" )
	cmdFinder=$( whereis -b fdfind fd find | awk '/: ./ { print $2 ; exit }' )

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
	local searchString=""
	searchString=$( printf '%s' "${1}" | sed --expression='s:\.:\\.:g' --expression='s:/:.*/.*:g' )

	# search paths ending with *searchString* ( no deeper paths after searchString allowed )
	command grep --ignore-case --extended-regexp "${searchString}"'[^/]*$' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::databaseSavePath()
{
	local directory="${1}"

	local iCounter=0
	local ignoreItem=""
	local ignoreItemFound=""

	[[ "${directory}" == "${HOME}" ]] || [[ "${directory}" == "/" ]] && return 0		# avoid saving $HOME and /

	while true ; do																		# search in ignore list

		(( ++iCounter ))

		ignoreItem=$( printf '%s|' "${SMARTCD_HIST_IGNORE}" | cut --delimiter='|' --fields=${iCounter} )
		[[ -z "${ignoreItem}" ]] && break

		ignoreItemFound=$( command grep --extended-regexp '/'"${ignoreItem}"'$|/'"${ignoreItem}"'/' <<< "${directory}" )

		if [[ -n "${ignoreItemFound}" ]] ; then

			__smartcd::databaseDeletePath "${directory}"								# remove ignored entry and leave function
			return 0
		fi
	done

	# remove previous entry
	__smartcd::databaseDeletePath "${directory}"

	# add to first row
	sed --in-place "1 s:^:${directory}\n:" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	# limit max records
	sed --in-place $(( SMARTCD_HIST_SIZE + 1 ))',$ d' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::databaseDeletePath()
{
	local directory="${1}"
	sed --in-place "\\:^${directory}$:d" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
}

function __smartcd::databaseCleanup()
{
	local IFS=

	local fTmp=""
	local line=""

	local iCounter=0
	local bIgnore="false"
	local ignoreItem=""
	local ignoreItemFound=""

	fTmp=$( mktemp )

	[[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ]] && __smartcd::databaseReset

	while read -r line || [[ -n "${line}" ]] ; do

		if [[ -d "${line}" ]] ; then

			iCounter=0
			bIgnore="false"

			# search in ignore list
			while true ; do

				(( ++iCounter ))

				ignoreItem=$( printf '%s|' "${SMARTCD_HIST_IGNORE}" | cut --delimiter='|' --fields=${iCounter} )
				[[ -z "${ignoreItem}" ]] && break

				ignoreItemFound=$( command grep --extended-regexp '/'"${ignoreItem}"'$|/'"${ignoreItem}"'/' <<< "${line}" )

				if [[ -n "${ignoreItemFound}" ]] ; then
					bIgnore="true"
					break
				fi
			done

			[[ "${bIgnore}" == "false" ]] && printf "%s\n" "${line}" >> "${fTmp}"
		fi

	done < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	awk '!seen[$0]++' "${fTmp}" > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	# remove empty lines
	sed --in-place '/^[[:blank:]]*$/ d' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"

	# at least one row needed
	(( $( command wc --lines < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ) == 0 )) && __smartcd::databaseReset

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

	[[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ]] && __smartcd::autoexecReset

	# autoexec file
	if [[ -f "${fAutoexec}" ]] && [[ ! -r "${fAutoexec}" ]] ; then

		printf 'smartcd - autoexec file [ %s ] : UNREADABLE\n' "${fAutoexec}"

	elif [[ -r "${fAutoexec}" ]] ; then

		checksum=$( md5sum "${fAutoexec}" | awk '{ print $1 }' )
		checksumStored=$( command grep --max-count=1 "${PWD}/${fAutoexec}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | cut --delimiter='|' --fields=2 )

		if [[ "${checksum}" == "${checksumStored}" ]] ; then
			bExecuted="true"
			# shellcheck disable=SC1090													# SC1090: Can't follow non-constant source. Use a directive to specify location
			source "${fAutoexec}"
		else
			printf 'smartcd - autoexec file [ %s ] : INVALID CHECKSUM\n' "${fAutoexec}"
		fi
	fi

	# global autoexec file
	if [[ -f "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ]] && [[ ! -r "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ]] ; then

		printf 'smartcd - autoexec file [ %s/%s ] : UNREADABLE\n' "${SMARTCD_CONFIG_FOLDER}" "${fAutoexec:1}"

	elif [[ -r "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" ]] && [[ "${bExecuted}" == "false" ]] ; then

		checksum=$( md5sum "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" | awk '{ print $1 }' )
		checksumStored=$( command grep --max-count=1 "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | cut --delimiter='|' --fields=2 )

		if [[ "${checksum}" == "${checksumStored}" ]] ; then
			# shellcheck disable=SC1090													# SC1090: Can't follow non-constant source. Use a directive to specify location
			source "${SMARTCD_CONFIG_FOLDER}/${fAutoexec:1}"
		else
			printf 'smartcd - autoexec file [ %s/%s ] : INVALID CHECKSUM\n' "${SMARTCD_CONFIG_FOLDER}" "${fAutoexec:1}"
		fi
	fi
}

function __smartcd::autoexecAdd()
{
	local fAutoexec=""
	local fPath=""
	local fName=""
	local checksum=""

	fAutoexec=$( realpath -- "${1}" )
	fPath=$( dirname -- "${fAutoexec}" )
	fName=$( basename -- "${fAutoexec}" )

	if [[ "${fPath}" == "${SMARTCD_CONFIG_FOLDER}" ]] && [[ "${fName}" != "on_entry.smartcd.sh" ]] && [[ "${fName}" != "on_leave.smartcd.sh" ]] ; then

		printf 'smartcd - autoexec file [ %s ] : INVALID FILENAME\n' "${fAutoexec}"
		return 2

	elif [[ "${fPath}" != "${SMARTCD_CONFIG_FOLDER}" ]] && [[ "${fName}" != ".on_entry.smartcd.sh" ]] && [[ "${fName}" != ".on_leave.smartcd.sh" ]] ; then

		printf 'smartcd - autoexec file [ %s ] : INVALID FILENAME\n' "${fAutoexec}"
		return 2

	elif [[ ! -r "${fAutoexec}" ]] ; then

		printf 'smartcd - autoexec file [ %s ] : UNREADABLE\n' "${fAutoexec}"
		return 2
	fi

	[[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ]] && __smartcd::autoexecReset

	checksum=$( md5sum "${fAutoexec}" | awk '{ print $1 }' )

	printf '%s|%s\n' "${fAutoexec}" "${checksum}" >> "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
	printf 'smartcd - autoexec file [ %s ] : ADDED\n' "${fAutoexec}"

	__smartcd::autoexecCleanup															# remove previous checksum
}

function __smartcd::autoexecCleanup()
{
	local IFS=

	local fTmp=""
	local line=""
	local fAutoexec=""
	local checksum=""
	local checksumStored=""

	fTmp=$( mktemp )

	[[ ! -f "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ]] && __smartcd::autoexecReset

	while read -r line || [[ -n "${line}" ]] ; do

		fAutoexec=$( cut --delimiter='|' --fields=1 <<< "${line}" )
		checksumStored=$( cut --delimiter='|' --fields=2 <<< "${line}" )
		checksum=""

		[[ -r "${fAutoexec}" ]] && checksum=$( md5sum "${fAutoexec}" | awk '{ print $1 }' )

		[[ "${checksum}" == "${checksumStored}" ]] && printf '%s\n' "${line}" >> "${fTmp}"

	done < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# order file and remove duplicated entries
	sort --unique "${fTmp}" > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# remove empty lines
	sed --in-place '/^[[:blank:]]*$/ d' "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"

	# at least one row needed
	(( $( wc --lines < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" ) == 0 )) && __smartcd::autoexecReset

	command rm --force "${fTmp}"
	chmod 600 "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
}

function __smartcd::autoexecReset()
{
	mkdir --parents "${SMARTCD_CONFIG_FOLDER}"
	printf '\n' > "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
	chmod 600 "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}"
}

function __smartcd::askAndReset()
{
	local answer=""

	printf 'smartcd - paths database file [ %s/%s ] will be erased\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_HIST_FILE}"

	printf '\033[1m'"Continue [y/n]? "'\033[22m'
	answer="" ; read -r answer

	case "${answer}" in
		Y|y|YES|yes|Yes)
			__smartcd::databaseReset
			printf 'smartcd - paths database file [ %s/%s ] : RESET\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_HIST_FILE}"
		;;

		*)
			printf 'smartcd - paths database file [ %s/%s ] : CANCELLED\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_HIST_FILE}"
		;;
	esac

	printf '\nsmartcd - autoexec database file [ %s/%s ] will be erased\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_AUTOEXEC_FILE}"
	printf '\033[1m'"Continue [y/n]? "'\033[22m'
	answer="" ; read -r answer

	case "${answer}" in
		Y|y|YES|yes|Yes)
			__smartcd::autoexecReset
			printf 'smartcd - autoexec database file [ %s/%s ] : RESET\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_AUTOEXEC_FILE}"
		;;

		*)
			printf 'smartcd - autoexec database file [ %s/%s ] : CANCELLED\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_AUTOEXEC_FILE}"
		;;
	esac
}

function __smartcd::upgrade()
{
	local -r SRC_REMOTE="https://raw.githubusercontent.com/lfromanini/smartcd/main/smartcd.sh"

	local returnCode=0
	local answer=""
	local fScriptInstalled=""
	local fScriptRemote=""
	local versionInstalled=""
	local versionRemote=""

	versionInstalled=$( __smartcd::printVersion | cut --delimiter=' ' --fields=2 )

	if [[ -n "${BASH_VERSION}" ]] ; then

		fScriptInstalled=$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )

	elif [[ -n "${ZSH_VERSION}" ]] ; then

		# shellcheck disable=SC2296														# SC2296: Parameter expansions can't start with `{`. Double check syntax.
		# shellcheck disable=SC2298														# SC2298: `${$x}` is invalid. For expansion, use ${x}. For indirection, use arrays, ${!x} or (for sh) eval.
		fScriptInstalled=${${(%):-%x}:A:h}

	else

		printf "Can't use smartcd : unknown shell\n"
		return 1
	fi

	fScriptInstalled+="/smartcd.sh"

	if [[ ! -w "${fScriptInstalled}" ]] ; then

		printf '\nsmartcd - cannot upgrade read only file [ %s ]\nsmartcd - aborting...\n' "${fScriptInstalled}"
		return 1
	fi

	printf 'smartcd - downloading remote version...\n\n'
	fScriptRemote=$( mktemp )

	curl --location --output "${fScriptRemote}" "${SRC_REMOTE}"
	returnCode=$?

	if (( returnCode != 0 )) ; then

		command rm --force "${fScriptRemote}"
		printf 'smartcd - could not download remote version : FAILED\n'
		return ${returnCode}
	fi

	versionRemote=$( command grep 'local -r VERSION=' "${fScriptRemote}" | command grep --invert-match 'grep' | cut --delimiter='"' --fields=2 )

	if [[ "${versionInstalled}" == "${versionRemote}" ]] ; then

		printf '\nsmartcd - no need to upgrade [ %s ]\n' "${versionInstalled}"
		command rm --force "${fScriptRemote}"
		return 0
	fi

	printf '\nsmartcd - upgrade available [ %s -> %s ]\n' "${versionInstalled}" "${versionRemote}"
	printf '\033[1m'"Upgrade [y/n]? "'\033[22m'
	answer="" ; read -r answer

	case "${answer}" in
		Y|y|YES|yes|Yes)
			printf '\nsmartcd - pgrading file [ %s ]...\n' "${versionInstalled}"
			command mv --force "${fScriptRemote}" "${fScriptInstalled}"
			returnCode=$?

			if (( returnCode == 0 )) ; then

				printf 'smartcd - upgrade  [ %s -> %s ] : UPGRADED\n' "${versionInstalled}" "${versionRemote}"
				# shellcheck disable=SC1090												# SC1090: Can't follow non-constant source. Use a directive to specify location
				source "${fScriptInstalled}"

			else

				command rm --force "${fScriptRemote}"
				printf 'smartcd - upgrade  [ %s -> %s ] : FAILED\n' "${versionInstalled}" "${versionRemote}"
			fi
		;;

		*)
			command rm --force "${fScriptRemote}"
			printf '\nsmartcd - upgrade  [ %s -> %s ] : CANCELLED\n' "${versionInstalled}" "${versionRemote}"
		;;
	esac

	return ${returnCode}
}

function __smartcd::printVersion()
{
	# local readonly VERSION="2.4.5"													# force update from version 2.4.4
	local -r VERSION="2.5.0"
	printf 'smartcd %s\n' "${VERSION}"
}

function __smartcd::printHelp()
{
	__smartcd::printVersion

	cat <<-EOF
		A mnemonist cd command with autoexec feature

		Options:

		smartcd [OPTIONS]

		    -l, --list                list paths saved at database file and allowed autexec files
		                              also print ignored paths list

		    -c, --cleanup             remove incorrect entries from paths and autoexec database files

		    -e, --edit                manually edit paths database file
		                              autoexec database file should not be manually edited

		    -r, --reset               reset database file to original state

		        --autoexec="[FILE]"   for security reasons, authorize file to be autoexecuted
		                              if FILE contents changes, it must be authorized again
		                              FILE can be relative to folder:
		                                  /path/to/.on_entry.smartcd.sh
		                                  /path/to/.on_leave.smartcd.sh
		                              or global ( wihout the "." at filename ):
		                                  ${SMARTCD_CONFIG_FOLDER}/on_entry.smartcd.sh
		                                  ${SMARTCD_CONFIG_FOLDER}/on_leave.smartcd.sh
		                              ( if relative file is executed, global will be skipped for the given folder )

		    -u, --upgrade             self upgrade if a new version is available online

		    -V, --version             output version information

		    -h, --help                display this help

		cd [ARGS]

		        --                    list last directories and navigate to the selected entry

		        [STRING]              searchs in filesystem and in database file for partial matches

		Databases:

		    ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}
		    ${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}
	EOF
}

function smartcd()
{
	local arg=""
	local fAutoexec=""

	[[ -z "${1}" ]] && set -- "--help"

	for arg in "$@" ; do

		case "${arg}" in
			-l|--list)
				printf 'smartcd - paths database file [ %s/%s ] contents:\n\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_HIST_FILE}"
				command grep --color=auto --line-number "" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" 2>/dev/null
				printf '\nsmartcd - autoexec database file [ %s/%s ] contents:\n\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_AUTOEXEC_FILE}"
				{ cut --delimiter='|' --fields="1" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_AUTOEXEC_FILE}" | command grep --color=auto --line-number --extended-regexp 'on_entry|on_leave' ; } 2>/dev/null

				# shellcheck disable=SC2016												# SC2016: Expressions don't expand in single quotes, use double quotes for that.
				printf '\nsmartcd - ignore list [ $SMARTCD_HIST_IGNORE ] sorted contents:\n'
				# shellcheck disable=SC2016												# SC2016: Expressions don't expand in single quotes, use double quotes for that.
				printf '          ( always ignored "/" and "$HOME" )\n\n'
				printf "%s\n" "${SMARTCD_HIST_IGNORE}" | sed 's:|:'"\n"':g' | sort --unique
			;;

			-c|--cleanup)
				__smartcd::databaseCleanup
				printf 'smartcd - paths database file [ %s/%s ] : CLEAR\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_HIST_FILE}"
				__smartcd::autoexecCleanup
				printf 'smartcd - autoexec database file [ %s/%s ] : CLEAR\n' "${SMARTCD_CONFIG_FOLDER}" "${SMARTCD_AUTOEXEC_FILE}"
			;;

			-e|--edit)
				if [[ -n "${EDITOR}" ]] ; then
					"${EDITOR}" "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}"
					# at least one row needed
					(( $( wc --lines < "${SMARTCD_CONFIG_FOLDER}/${SMARTCD_HIST_FILE}" ) > 0 )) || __smartcd::databaseReset
				else
					# shellcheck disable=SC2016											# SC2016: Expressions don't expand in single quotes, use double quotes for that.
					printf 'smartcd - editor variable not set [ $EDITOR ] : ABORTED\n'
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

			-V|--version)
				__smartcd::printVersion
				return 0
			;;

			-h|--help)
				__smartcd::printHelp
				return 0
			;;

			*)
				printf 'error: Found argument "%s" which was not expected. Try --help\n' "${arg}"
				return 1
			;;
		esac
	done
}

# bash builtin cd case insensitive
#[[ -n "${BASH_VERSION}" ]] && shopt -s cdspell

# key bindings
[[ -n "${BASH_VERSION}" ]] && bind '"\C-g":"cd --\n"'
[[ -n "${ZSH_VERSION}" ]] && bindkey -s '^g' 'cd --\n'

# aliases
alias cd="__smartcd::cd"
alias -- -="cd -"
alias cd..="cd .."
alias ..="cd .."
alias ..2="cd ../.."
alias ..3="cd ../../.."
