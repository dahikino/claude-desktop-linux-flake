#!/usr/bin/env bash

#===============================================================================
# Claude Desktop Debian Build Script
# Repackages Claude Desktop (Electron app) for Debian/Ubuntu Linux
#===============================================================================

# Global variables (set by functions, used throughout)
architecture=''
distro_family=''  # debian, rpm, nix, or unknown
claude_download_url=''
claude_exe_sha256=''
claude_exe_filename=''
version=''
release_tag=''  # Optional release tag (e.g., v1.3.2+claude1.1.799) for unique package versions
build_format=''  # Will be set based on distro if not specified
cleanup_action='yes'
perform_cleanup=false
test_flags_mode=false
local_exe_path=''
node_pty_dir=''
source_dir=''
original_user=''
original_home=''
project_root=''
work_dir=''
app_staging_dir=''
chosen_electron_module_path=''
electron_var=''
electron_var_re=''
asar_exec=''
claude_extract_dir=''
electron_resources_dest=''
node_pty_build_dir=''
final_output_path=''

# Package metadata (constants)
readonly PACKAGE_NAME='claude-desktop'
readonly MAINTAINER='Claude Desktop Linux Maintainers'
readonly DESCRIPTION='Claude Desktop for Linux'

#===============================================================================
# Utility Functions
#===============================================================================

check_command() {
	if ! command -v "$1" &> /dev/null; then
		echo "$1 not found"
		return 1
	else
		echo "$1 found"
		return 0
	fi
}

section_header() {
	echo -e "\033[1;36m--- $1 ---\033[0m"
}

section_footer() {
	echo -e "\033[1;36m--- End $1 ---\033[0m"
}

verify_sha256() {
	local file_path="$1"
	local expected_hash="$2"
	local label="${3:-file}"

	if [[ -z $expected_hash ]]; then
		echo "Warning: No SHA-256 hash for ${label}," \
			'skipping verification' >&2
		return 0
	fi

	echo "Verifying SHA-256 checksum for ${label}..."
	local actual_hash _
	read -r actual_hash _ < <(sha256sum "$file_path")

	if [[ $actual_hash != "$expected_hash" ]]; then
		echo "SHA-256 mismatch for ${label}!" >&2
		echo "  Expected: $expected_hash" >&2
		echo "  Actual:   $actual_hash" >&2
		return 1
	fi

	echo "SHA-256 verified: ${label}"
}

#===============================================================================
# Setup Functions
#===============================================================================

detect_architecture() {
	section_header 'Architecture Detection'
	echo 'Detecting system architecture...'

	local raw_arch
	raw_arch=$(uname -m) || {
		echo 'Failed to detect architecture' >&2
		exit 1
	}
	echo "Detected machine architecture: $raw_arch"

	case "$raw_arch" in
		x86_64)
			claude_download_url='https://downloads.claude.ai/releases/win32/x64/1.569.0/Claude-49894ad878c985b0dd77178b75b353f11481ebf4.exe'
			claude_exe_sha256='34d6c8371ec8a5f57c690192b134bba64433103becd254f28058738ef4031ced'
			architecture='amd64'
			claude_exe_filename='Claude-Setup-x64.exe'
			echo 'Configured for amd64 (x86_64) build.'
			;;
		aarch64)
			claude_download_url='https://downloads.claude.ai/releases/win32/arm64/1.569.0/Claude-49894ad878c985b0dd77178b75b353f11481ebf4.exe'
			claude_exe_sha256='fd9110fe113de039b79f7d693d9a9a660e54cfc2c6af120ff403e07315b27bf3'
			architecture='arm64'
			claude_exe_filename='Claude-Setup-arm64.exe'
			echo 'Configured for arm64 (aarch64) build.'
			;;
		*)
			echo "Unsupported architecture: $raw_arch. This script supports x86_64 (amd64) and aarch64 (arm64)." >&2
			exit 1
			;;
	esac

	echo "Target Architecture: $architecture"
	section_footer 'Architecture Detection'
}

detect_distro() {
	section_header 'Distribution Detection'
	echo 'Detecting Linux distribution family...'

	if [[ -f /etc/debian_version ]]; then
		distro_family='debian'
		echo "Detected Debian-based distribution"
		echo "  Debian version: $(cat /etc/debian_version)"
	elif [[ -f /etc/fedora-release ]]; then
		distro_family='rpm'
		echo "Detected Fedora"
		echo "  $(cat /etc/fedora-release)"
	elif [[ -f /etc/redhat-release ]]; then
		distro_family='rpm'
		echo "Detected Red Hat-based distribution"
		echo "  $(cat /etc/redhat-release)"
	elif [[ -f /etc/NIXOS ]]; then
		distro_family='nix'
		echo "Detected NixOS"
	else
		distro_family='unknown'
		echo "Warning: Could not detect distribution family"
		echo "  AppImage build will still work, but native packages (deb/rpm) may not"
	fi

	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	section_footer 'Distribution Detection'
}

check_system_requirements() {
	# Allow running as root in CI/container environments
	if (( EUID == 0 )); then
		if [[ -n ${CI:-} || -n ${GITHUB_ACTIONS:-} || -f /.dockerenv ]]; then
			echo 'Running as root in CI/container environment (allowed)'
		else
			echo 'This script should not be run using sudo or as the root user.' >&2
			echo 'It will use sudo when needed for specific actions (may prompt for password).' >&2
			echo 'Please run as a normal user.' >&2
			exit 1
		fi
	fi

	original_user=$(whoami)
	original_home=$(getent passwd "$original_user" | cut -d: -f6)
	if [[ -z $original_home ]]; then
		echo "Could not determine home directory for user $original_user." >&2
		exit 1
	fi
	echo "Running as user: $original_user (Home: $original_home)"

	# Check for NVM and source it if found
	if [[ -d $original_home/.nvm ]]; then
		echo "Found NVM installation for user $original_user, checking for Node.js 20+..."
		export NVM_DIR="$original_home/.nvm"
		if [[ -s $NVM_DIR/nvm.sh ]]; then
			# shellcheck disable=SC1091
			\. "$NVM_DIR/nvm.sh"
			local node_bin_path=''
			node_bin_path=$(nvm which current | xargs dirname 2>/dev/null || \
				find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

			if [[ -n $node_bin_path && -d $node_bin_path ]]; then
				echo "Adding NVM Node bin path to PATH: $node_bin_path"
				export PATH="$node_bin_path:$PATH"
			else
				echo 'Warning: Could not determine NVM Node bin path.'
			fi
		else
			echo 'Warning: nvm.sh script not found or not sourceable.'
		fi
	fi

	echo 'System Information:'
	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	echo "Target Architecture: $architecture"
}

parse_arguments() {
	section_header 'Argument Parsing'

	project_root="$(pwd)"
	work_dir="$project_root/build"
	app_staging_dir="$work_dir/electron-app"

	# Set default build format based on detected distro
	case "$distro_family" in
		debian) build_format='deb' ;;
		rpm) build_format='rpm' ;;
		nix) build_format='nix' ;;
		*) build_format='appimage' ;;
	esac

	while (( $# > 0 )); do
		case "$1" in
			-b|--build|-c|--clean|-e|--exe|-r|--release-tag|-s|--source-dir|--node-pty-dir)
				if [[ -z ${2:-} || $2 == -* ]]; then
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				case "$1" in
					-b|--build) build_format="$2" ;;
					-c|--clean) cleanup_action="$2" ;;
					-e|--exe) local_exe_path="$2" ;;
					-r|--release-tag) release_tag="$2" ;;
					-s|--source-dir) source_dir="$2" ;;
					--node-pty-dir) node_pty_dir="$2" ;;
				esac
				shift 2
				;;
			--test-flags)
				test_flags_mode=true
				shift
				;;
			-h|--help)
				echo "Usage: $0 [--build deb|rpm|appimage|nix] [--clean yes|no] [--exe /path/to/installer.exe] [--source-dir /path] [--release-tag TAG] [--test-flags]"
				echo '  --build: Specify the build format (deb, rpm, appimage, or nix).'
				echo "           Default: auto-detected based on distro (current: $build_format)"
				echo '  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes'
				echo '  --exe:   Use a local Claude installer exe instead of downloading'
				echo '  --source-dir: Path to repo root for scripts/ and assets (default: project root)'
				echo '  --node-pty-dir: Path to pre-built node-pty package (skips npm install)'
				echo '  --release-tag: Release tag (e.g., v1.3.2+claude1.1.799) to append wrapper version to package'
				echo '  --test-flags: Parse flags, print results, and exit without building.'
				exit 0
				;;
			*)
				echo "Unknown option: $1" >&2
				echo 'Use -h or --help for usage information.' >&2
				exit 1
				;;
		esac
	done

	# source_dir is where scripts/assets live (default: project_root)
	source_dir="${source_dir:-$project_root}"

	# Validate arguments
	build_format="${build_format,,}"
	cleanup_action="${cleanup_action,,}"

	if [[ ! -d $source_dir ]]; then
		echo "Error: --source-dir path does not exist: $source_dir" >&2
		exit 1
	fi
	if [[ -n $node_pty_dir && ! -d $node_pty_dir ]]; then
		echo "Error: --node-pty-dir path does not exist: $node_pty_dir" >&2
		exit 1
	fi

	if [[ $build_format != 'deb' && $build_format != 'rpm' && $build_format != 'appimage' && $build_format != 'nix' ]]; then
		echo "Invalid build format specified: '$build_format'. Must be 'deb', 'rpm', 'appimage', or 'nix'." >&2
		exit 1
	fi

	# Warn if building native package for wrong distro
	if [[ $build_format == 'deb' && $distro_family != 'debian' ]]; then
		echo "Warning: Building .deb package on non-Debian system ($distro_family). This may fail." >&2
	elif [[ $build_format == 'rpm' && $distro_family != 'rpm' ]]; then
		echo "Warning: Building .rpm package on non-RPM system ($distro_family). This may fail." >&2
	fi
	if [[ $cleanup_action != 'yes' && $cleanup_action != 'no' ]]; then
		echo "Invalid cleanup option specified: '$cleanup_action'. Must be 'yes' or 'no'." >&2
		exit 1
	fi

	echo "Selected build format: $build_format"
	echo "Cleanup intermediate files: $cleanup_action"

	[[ $cleanup_action == 'yes' ]] && perform_cleanup=true

	section_footer 'Argument Parsing'
}

check_dependencies() {
	echo 'Checking dependencies...'
	local deps_to_install=''
	local common_deps='p7zip wget wrestool icotool convert'
	local all_deps="$common_deps"

	# Add format-specific dependencies
	case "$build_format" in
		deb) all_deps="$all_deps dpkg-deb" ;;
		rpm) all_deps="$all_deps rpmbuild" ;;
	esac

	# Command-to-package mappings per distro family
	declare -A debian_pkgs=(
		[p7zip]='p7zip-full' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='imagemagick'
		[dpkg-deb]='dpkg-dev' [rpmbuild]='rpm'
	)
	declare -A rpm_pkgs=(
		[p7zip]='p7zip p7zip-plugins' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='ImageMagick'
		[dpkg-deb]='dpkg' [rpmbuild]='rpm-build'
	)

	local cmd
	for cmd in $all_deps; do
		if ! check_command "$cmd"; then
			case "$distro_family" in
				debian)
					deps_to_install="$deps_to_install ${debian_pkgs[$cmd]}"
					;;
				rpm)
					deps_to_install="$deps_to_install ${rpm_pkgs[$cmd]}"
					;;
				*)
					echo "Warning: Cannot auto-install '$cmd' on unknown distro. Please install manually." >&2
					;;
			esac
		fi
	done

	if [[ -n $deps_to_install ]]; then
		echo "System dependencies needed:$deps_to_install"

		# Determine if we need sudo (skip if already root)
		local sudo_cmd='sudo'
		if (( EUID == 0 )); then
			sudo_cmd=''
			echo 'Installing as root (no sudo needed)...'
		else
			echo 'Attempting to install using sudo...'
			# Check if we can sudo without a password first
			if sudo -n true 2>/dev/null; then
				echo 'Passwordless sudo detected.'
			elif ! sudo -v; then
				echo 'Failed to validate sudo credentials. Please ensure you can run sudo.' >&2
				exit 1
			fi
		fi

		case "$distro_family" in
			debian)
				if ! $sudo_cmd apt update; then
					echo "Failed to run 'apt update'." >&2
					exit 1
				fi
				# shellcheck disable=SC2086
				if ! $sudo_cmd apt install -y $deps_to_install; then
					echo "Failed to install dependencies using 'apt install'." >&2
					exit 1
				fi
				;;
			rpm)
				# shellcheck disable=SC2086
				if ! $sudo_cmd dnf install -y $deps_to_install; then
					echo "Failed to install dependencies using 'dnf install'." >&2
					exit 1
				fi
				;;
			*)
				echo "Cannot auto-install dependencies on unknown distro." >&2
				echo "Please install these packages manually: $deps_to_install" >&2
				exit 1
				;;
		esac
		echo 'System dependencies installed successfully.'
	fi
}

setup_work_directory() {
	rm -rf "$work_dir"
	mkdir -p "$work_dir" || exit 1
	mkdir -p "$app_staging_dir" || exit 1
}

setup_nodejs() {
	section_header 'Node.js Setup'
	echo 'Checking Node.js version...'

	local node_version_ok=false
	if command -v node &> /dev/null; then
		local node_version node_major
		node_version=$(node --version | cut -d'v' -f2)
		node_major="${node_version%%.*}"
		echo "System Node.js version: v$node_version"

		if (( node_major >= 20 )); then
			echo "System Node.js version is adequate (v$node_version)"
			node_version_ok=true
		else
			echo "System Node.js version is too old (v$node_version). Need v20+"
		fi
	else
		echo 'Node.js not found in system'
	fi

	if [[ $node_version_ok == true ]]; then
		section_footer 'Node.js Setup'
		return 0
	fi

	# Node.js version inadequate - install locally
	echo 'Installing Node.js v20 locally in build directory...'

	local node_arch
	case "$architecture" in
		amd64) node_arch='x64' ;;
		arm64) node_arch='arm64' ;;
		*)
			echo "Unsupported architecture for Node.js: $architecture" >&2
			exit 1
			;;
	esac

	local node_version_to_install='20.18.1'
	local node_tarball="node-v${node_version_to_install}-linux-${node_arch}.tar.xz"
	local node_url="https://nodejs.org/dist/v${node_version_to_install}/${node_tarball}"
	local node_install_dir="$work_dir/node"

	echo "Downloading Node.js v${node_version_to_install} for ${node_arch}..."
	cd "$work_dir" || exit 1
	if ! wget -O "$node_tarball" "$node_url"; then
		echo "Failed to download Node.js from $node_url" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# Verify against official Node.js checksums
	local shasums_url node_expected_sha256
	shasums_url="https://nodejs.org/dist/v${node_version_to_install}/SHASUMS256.txt"
	node_expected_sha256=$(
		wget -qO- "$shasums_url" \
			| grep -F "$node_tarball" \
			| awk '{print $1}'
	) || true

	if ! verify_sha256 "$work_dir/$node_tarball" \
		"$node_expected_sha256" 'Node.js tarball'; then
		cd "$project_root" || exit 1
		exit 1
	fi

	echo 'Extracting Node.js...'
	if ! tar -xf "$node_tarball"; then
		echo 'Failed to extract Node.js tarball' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	mv "node-v${node_version_to_install}-linux-${node_arch}" "$node_install_dir" || exit 1
	export PATH="$node_install_dir/bin:$PATH"

	if command -v node &> /dev/null; then
		echo "Local Node.js installed successfully: $(node --version)"
	else
		echo 'Failed to install local Node.js' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	rm -f "$node_tarball"
	cd "$project_root" || exit 1
	section_footer 'Node.js Setup'
}

setup_electron_asar() {
	section_header 'Electron & Asar Handling'

	echo "Ensuring local Electron and Asar installation in $work_dir..."
	cd "$work_dir" || exit 1

	if [[ ! -f package.json ]]; then
		echo "Creating temporary package.json in $work_dir for local install..."
		echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
	fi

	local electron_dist_path="$work_dir/node_modules/electron/dist"
	local asar_bin_path="$work_dir/node_modules/.bin/asar"
	local install_needed=false

	[[ ! -d $electron_dist_path ]] && echo 'Electron distribution not found.' && install_needed=true
	[[ ! -f $asar_bin_path ]] && echo 'Asar binary not found.' && install_needed=true

	if [[ $install_needed == true ]]; then
		echo "Installing Electron and Asar locally into $work_dir..."
		if ! npm install --no-save electron @electron/asar; then
			echo 'Failed to install Electron and/or Asar locally.' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo 'Electron and Asar installation command finished.'
	else
		echo 'Local Electron distribution and Asar binary already present.'
	fi

	if [[ -d $electron_dist_path ]]; then
		echo "Found Electron distribution directory at $electron_dist_path."
		chosen_electron_module_path="$(realpath "$work_dir/node_modules/electron")"
		echo "Setting Electron module path for copying to $chosen_electron_module_path."
	else
		echo "Failed to find Electron distribution directory at '$electron_dist_path' after installation attempt." >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if [[ -f $asar_bin_path ]]; then
		asar_exec="$(realpath "$asar_bin_path")"
		echo "Found local Asar binary at $asar_exec."
	else
		echo "Failed to find Asar binary at '$asar_bin_path' after installation attempt." >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	cd "$project_root" || exit 1

	if [[ -z $chosen_electron_module_path || ! -d $chosen_electron_module_path ]]; then
		echo 'Critical error: Could not resolve a valid Electron module path to copy.' >&2
		exit 1
	fi

	echo "Using Electron module path: $chosen_electron_module_path"
	echo "Using asar executable: $asar_exec"
	section_footer 'Electron & Asar Handling'
}

#===============================================================================
# Download and Extract Functions
#===============================================================================

download_claude_installer() {
	section_header 'Download the latest Claude executable'

	local claude_exe_path="$work_dir/$claude_exe_filename"

	if [[ -n $local_exe_path ]]; then
		echo "Using local Claude installer: $local_exe_path"
		if [[ ! -f $local_exe_path ]]; then
			echo "Local installer file not found: $local_exe_path" >&2
			exit 1
		fi
		cp "$local_exe_path" "$claude_exe_path" || exit 1
		echo 'Local installer copied to build directory'
	else
		echo "Downloading Claude Desktop installer for $architecture..."
		if ! wget -O "$claude_exe_path" "$claude_download_url"; then
			echo "Failed to download Claude Desktop installer from $claude_download_url" >&2
			exit 1
		fi
		echo "Download complete: $claude_exe_filename"

		if ! verify_sha256 "$claude_exe_path" \
			"$claude_exe_sha256" 'Claude Desktop installer'; then
			exit 1
		fi
	fi

	echo "Extracting resources from $claude_exe_filename into separate directory..."
	claude_extract_dir="$work_dir/claude-extract"
	mkdir -p "$claude_extract_dir" || exit 1

	if ! 7z x -y "$claude_exe_path" -o"$claude_extract_dir"; then
		echo 'Failed to extract installer' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	cd "$claude_extract_dir" || exit 1
	local nupkg_path_relative
	nupkg_path_relative=$(find . -maxdepth 1 -name 'AnthropicClaude-*.nupkg' | head -1)

	if [[ -z $nupkg_path_relative ]]; then
		echo "Could not find AnthropicClaude nupkg file in $claude_extract_dir" >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "Found nupkg: $nupkg_path_relative (in $claude_extract_dir)"

	version=$(echo "$nupkg_path_relative" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
	if [[ -z $version ]]; then
		echo "Could not extract version from nupkg filename: $nupkg_path_relative" >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "Detected Claude version: $version"

	# Extract wrapper version from release tag if provided (e.g., v1.3.2+claude1.1.799 -> 1.3.2)
	if [[ -n $release_tag ]]; then
		local wrapper_version
		# Extract version between 'v' and '+claude' (e.g., v1.3.2+claude1.1.799 -> 1.3.2)
		wrapper_version=$(echo "$release_tag" | LC_ALL=C grep -oP '^v\K[0-9]+\.[0-9]+\.[0-9]+(?=\+claude)')
		if [[ -n $wrapper_version ]]; then
			version="${version}-${wrapper_version}"
			echo "Package version with wrapper suffix: $version"
		else
			echo "Warning: Could not extract wrapper version from release tag: $release_tag" >&2
		fi
	fi

	if ! 7z x -y "$nupkg_path_relative"; then
		echo 'Failed to extract nupkg' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo 'Resources extracted from nupkg'

	cd "$project_root" || exit 1
}

#===============================================================================
# Patching Functions
#===============================================================================

patch_app_asar() {
	echo 'Processing app.asar...'
	cp "$claude_extract_dir/lib/net45/resources/app.asar" "$app_staging_dir/" || exit 1
	cp -a "$claude_extract_dir/lib/net45/resources/app.asar.unpacked" "$app_staging_dir/" || exit 1
	cd "$app_staging_dir" || exit 1
	"$asar_exec" extract app.asar app.asar.contents || exit 1

	# Frame fix wrapper
	echo 'Creating BrowserWindow frame fix wrapper...'
	local original_main
	original_main=$(node -e "const pkg = require('./app.asar.contents/package.json'); console.log(pkg.main);")
	echo "Original main entry: $original_main"

	cp "$source_dir/scripts/frame-fix-wrapper.js" app.asar.contents/frame-fix-wrapper.js || exit 1

	cat > app.asar.contents/frame-fix-entry.js << EOFENTRY
// Load frame fix first
require('./frame-fix-wrapper.js');
// Then load original main
require('./${original_main}');
EOFENTRY

	# BrowserWindow frame/titleBarStyle patching is handled at runtime by
	# frame-fix-wrapper.js via a Proxy on require('electron'). No sed patches
	# needed — the wrapper detects popup vs main windows by their options and
	# applies frame:true/false accordingly.

	# Update package.json
	echo 'Modifying package.json to load frame fix and add node-pty...'
	node -e "
const fs = require('fs');
const pkg = require('./app.asar.contents/package.json');
pkg.originalMain = pkg.main;
pkg.main = 'frame-fix-entry.js';
pkg.optionalDependencies = pkg.optionalDependencies || {};
pkg.optionalDependencies['node-pty'] = '^1.0.0';
fs.writeFileSync('./app.asar.contents/package.json', JSON.stringify(pkg, null, 2));
console.log('Updated package.json: main entry and node-pty dependency');
"

	# Create stub native module
	echo 'Creating stub native module...'
	mkdir -p app.asar.contents/node_modules/@ant/claude-native || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		app.asar.contents/node_modules/@ant/claude-native/index.js || exit 1

	mkdir -p app.asar.contents/resources/i18n || exit 1
	cp "$claude_extract_dir/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/ || exit 1

	# Copy tray icons into asar so both packaged (process.resourcesPath)
	# and unpackaged (app.getAppPath()) code paths can find them
	cp "$claude_extract_dir/lib/net45/resources/Tray"* app.asar.contents/resources/ 2>/dev/null || \
		echo 'Warning: No tray icon files found for asar inclusion'

	# Patch title bar detection
	patch_titlebar_detection

	# Resolve which file holds the main-process code (code-split since 1.19367.0)
	resolve_main_bundle

	# Extract electron module variable name for tray patches
	extract_electron_variable

	# Fix incorrect nativeTheme variable references
	fix_native_theme_references

	# Patch tray menu handler
	patch_tray_menu_handler

	# Patch tray icon selection
	patch_tray_icon_selection

	# Patch menuBarEnabled to default to true when unset
	patch_menu_bar_default

	# Patch quick window
	patch_quick_window

	# Add Linux Claude Code support
	patch_linux_claude_code

	# Patch Cowork mode for Linux (TypeScript VM client + Unix socket)
	patch_cowork_linux

	# Copy cowork VM service daemon for Linux Cowork mode
	echo 'Installing cowork VM service daemon...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		app.asar.contents/cowork-vm-service.js || exit 1
	echo 'Cowork VM service daemon installed'

	verify_patched_syntax
}

# Build-time syntax gate over every patched main-process chunk.
#
# WHY: a patch that corrupts the bundle still BUILDS green — nothing here parses
# the JS — and only dies at runtime with a blank app. That shipped twice:
# `patch_quick_window` splicing into a const declarator, and the `_trayStartTime`
# initialiser landing inside a comma expression on 1.25927.0 ("SyntaxError:
# Unexpected identifier '_trayStartTime'", app would not launch). The cowork
# patches were dry-run checked by hand at the time; the sed-based tray patches
# were not, and that is exactly the gap this closes. Fail the build instead.
#
# Syntax only: node --check cannot tell us a patch is semantically wrong, just
# that the file still parses. That is the cheap half, and it is the half that
# has actually broken.
verify_patched_syntax() {
	echo 'Verifying patched bundle syntax (node --check)...'
	local f rc=0 checked=0
	local -a targets=()
	# The tray group, patched by the seds above.
	[[ -n ${main_bundle:-} && -f ${main_bundle:-} ]] && targets+=("$main_bundle")
	# Plus the exact set the cowork pass rewrote, as reported by the node script.
	if [[ -n ${cowork_changed_list:-} && -f ${cowork_changed_list:-} ]]; then
		local line
		while IFS= read -r line; do
			[[ -n $line && -f $line ]] && targets+=("$line")
		done <"$cowork_changed_list"
	fi
	# Deduplicate: main_bundle is usually in the cowork set too.
	mapfile -t targets < <(printf '%s\n' "${targets[@]}" | sort -u)
	for f in "${targets[@]}"; do
		[[ -f $f ]] || continue
		checked=$((checked + 1))
		if ! node --check "$f" 2>/dev/null; then
			echo "  BROKEN: ${f#"$build_dir"/}" >&2
			node --check "$f" 2>&1 | head -3 >&2
			rc=1
		fi
	done
	if [[ $rc -ne 0 ]]; then
		echo 'Patched bundle does not parse — refusing to package a dead app.' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  $checked patched chunk(s) parse cleanly"
	echo '##############################################################'
}

patch_titlebar_detection() {
	echo '##############################################################'
	echo "Removing '!' from 'if (\"!\"isWindows && isMainWindow) return null;'"
	echo 'detection flag to enable title bar'

	local search_base='app.asar.contents/.vite/renderer/main_window/assets'
	local target_pattern='MainWindowPage-*.js'

	echo "Searching for '$target_pattern' within '$search_base'..."
	local target_files
	mapfile -t target_files < <(find "$search_base" -type f -name "$target_pattern")
	local num_files=${#target_files[@]}

	case $num_files in
		0)
			echo "Error: No file matching '$target_pattern' found within '$search_base'." >&2
			exit 1
			;;
		1)
			local target_file="${target_files[0]}"
			echo "Found target file: $target_file"
			sed -i -E 's/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g' "$target_file"

			if grep -q -E 'if\(![a-zA-Z]+[[:space:]]*&&[[:space:]]*[a-zA-Z]+\)' "$target_file"; then
				echo "Error: Failed to replace patterns in $target_file." >&2
				exit 1
			fi
			echo "Successfully replaced patterns in $target_file"
			;;
		*)
			echo "Error: Expected exactly one file matching '$target_pattern' within '$search_base', but found $num_files." >&2
			exit 1
			;;
	esac
	echo '##############################################################'
}

# Since 1.25927.0 the minifier emits template literals instead of double-quoted
# strings: `process.platform===\`win32\`` where older builds wrote
# `process.platform==="win32"`. Every anchor below therefore matches the quote
# character as a class instead of hardcoding one. Note this applies to JS string
# LITERALS only — embedded JSON keys kept their double quotes
# (`"win32-x64":{"binary":…}`), so a blanket quote substitution would corrupt them.
# Emitting double quotes in the REPLACEMENTS stays valid either way; only the
# matching side needs to be quote-agnostic.
readonly Q='["`]'

build_dir='app.asar.contents/.vite/build'

# Every main-process file, newest layouts included. 1.25927.0 added a second
# entry graph (`index2.chunk-*.js`) that the old index.js/index.chunk-* glob
# never looked at — the availability gate and the os-platform helper both live
# there now.
main_chunks() {
	local f
	# index.pre.js : entrée main de 1.32885.1 (package.json "main"), qui a
	# remplacé index.js. Les deux globs chunk couvrent le reste ; les fichiers
	# nommés (coworkArtifact.js, buddy.js…) sont exclus à dessein — des ancres
	# génériques (win32, cowork…) y matcheraient le MAUVAIS fichier.
	for f in "$build_dir"/index.js "$build_dir"/index.pre.js \
		"$build_dir"/index.chunk-*.js "$build_dir"/index2.chunk-*.js; do
		[[ -f $f ]] && printf '%s\n' "$f"
	done
}

# Print the first main-process file whose content matches a PCRE, or nothing.
# Anchors are content-based by design: the content hashes in the filenames
# change every release and must never be hardcoded.
find_chunk() {
	local re="$1" f
	# Collected into an array rather than read from a process substitution:
	# returning on the first hit would leave main_chunks writing into a closed
	# pipe, and every remaining printf reports "write error: Broken pipe".
	local -a chunks
	mapfile -t chunks < <(main_chunks)
	for f in "${chunks[@]}"; do
		if grep -qP -- "$re" "$f"; then
			printf '%s\n' "$f"
			return 0
		fi
	done
	return 1
}

resolve_main_bundle() {
	# Up to 1.24012.11 the whole main process — tray, nativeTheme, os-platform
	# AND cowork — sat in a single `index.chunk-<hash>.js`, so one resolved
	# bundle served every patch. 1.25927.0 split it apart: the tray/theme group
	# stayed in index.js, cowork moved to its own chunk, the availability gate to
	# an index2 chunk. `main_bundle` is now only the TRAY group; anything else
	# resolves its own file through find_chunk.
	echo 'Resolving main-process bundle...'
	if main_bundle=$(find_chunk "on\(${Q}menuBarEnabled${Q},\(?\(\)=>\{"); then
		echo "  Tray/main bundle: ${main_bundle#"$build_dir"/}"
		echo '##############################################################'
		return 0
	fi
	echo 'Failed to resolve main-process bundle (no file with the tray handler)' >&2
	cd "$project_root" || exit 1
	exit 1
}

extract_electron_variable() {
	echo 'Extracting electron module variable name...'
	local index_js="$main_bundle"

	electron_var=$(grep -oP "\\\$?\w+(?=\s*=\s*require\(${Q}electron${Q}\))" \
		"$index_js" | head -1)
	if [[ -z $electron_var ]]; then
		electron_var=$(grep -oP '(?<=new )\$?\w+(?=\.Tray\b)' \
			"$index_js" | head -1)
	fi
	if [[ -z $electron_var ]]; then
		echo 'Failed to extract electron variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	electron_var_re="${electron_var//\$/\\$}"
	echo "  Found electron variable: $electron_var"
	echo '##############################################################'
}

fix_native_theme_references() {
	echo 'Fixing incorrect nativeTheme variable references...'
	local index_js="$main_bundle"

	local wrong_refs
	mapfile -t wrong_refs < <(
		grep -oP '\$?\w+(?=\.nativeTheme)' "$index_js" \
			| sort -u \
			| grep -Fxv "$electron_var" || true
	)

	if (( ${#wrong_refs[@]} == 0 )); then
		echo '  All nativeTheme references are correct'
		echo '##############################################################'
		return
	fi

	local ref ref_re
	for ref in "${wrong_refs[@]}"; do
		echo "  Replacing: $ref.nativeTheme -> $electron_var.nativeTheme"
		ref_re="${ref//\$/\\$}"
		sed -i -E \
			"s/${ref_re}\.nativeTheme/${electron_var_re}.nativeTheme/g" \
			"$index_js"
	done
	echo '##############################################################'
}

patch_tray_menu_handler() {
	echo 'Patching tray menu handler...'
	local index_js="$main_bundle"

	local js_ident='[$A-Za-z_][$0-9A-Za-z_]*'
	local tray_func tray_func_re tray_var tray_var_re first_const
	# 1.32885.1: l'arrow du handler est enveloppée d'une paire de parenthèses
	# supplémentaire — `on(\`menuBarEnabled\`,(()=>{cvr()}))` — d'où le `\(?`.
	tray_func=$(grep -oP \
		"on\(${Q}menuBarEnabled${Q},\(?\(\)=>\{\K${js_ident}(?=\(\)\})" \
		"$index_js" | head -1)
	if [[ -z $tray_func ]]; then
		echo 'Failed to extract tray menu function name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	tray_func_re=$(printf '%s' "$tray_func" | sed 's/[][\\.^$*+?{}()|/]/\\&/g')
	echo "  Found tray function: $tray_func"

	# The tray var is whatever gets assigned `new <electron>.Tray(...)`.
	# Older bundles declared it as `});let <var>=null;function <trayFunc>`,
	# but newer ones use a multi-var `let a=null,b=null;` before a different
	# helper, so anchor on the Tray constructor instead (stable across versions).
	tray_var=$(grep -oP \
		"${js_ident}(?==new ${electron_var_re}\.Tray\()" \
		"$index_js" | head -1)
	if [[ -z $tray_var ]]; then
		echo 'Failed to extract tray variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	tray_var_re=$(printf '%s' "$tray_var" | sed 's/[][\\.^$*+?{}()|/]/\\&/g')
	echo "  Found tray variable: $tray_var"

	sed -i "s/function ${tray_func_re}(){/async function ${tray_func}(){/g" \
		"$index_js"

	# 1.25927.0 declares this with `let`, not `const`.
	first_const=$(grep -oP \
		"async function ${tray_func_re}\(\)\{.*?(?:const|let|var) \K${js_ident}(?==)" \
		"$index_js" | head -1)
	if [[ -z $first_const ]]; then
		echo 'Failed to extract first const in function' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found first const variable: $first_const"

	# Add mutex guard to prevent concurrent tray rebuilds
	if ! grep -qF "${tray_func}._running" "$index_js"; then
		sed -i "s/async function ${tray_func_re}(){/async function ${tray_func}(){if(${tray_func}._running)return;${tray_func}._running=true;setTimeout(()=>${tray_func}._running=false,1500);/g" \
			"$index_js"
		echo "  Added mutex guard to ${tray_func}()"
	fi

	# Add DBus cleanup delay after tray destroy
	if ! grep -qF "await new Promise(r=>setTimeout(r,250))" "$index_js"; then
		# Forme ≤1.25927.0 : `VAR&&(VAR.destroy(),VAR=null)` n'importe où.
		sed -i "s/${tray_var_re}&&(${tray_var_re}\.destroy(),${tray_var_re}=null)/${tray_var}\&\&(${tray_var}.destroy(),${tray_var}=null,await new Promise(r=>setTimeout(r,250)))/g" \
			"$index_js"
		# Forme 1.32885.1 : le teardown vit dans le catch du rebuild (cvr,
		# rendue async ci-dessus) — `(J9.destroy(),J9=null,Y9=null),fvr(!0)`.
		# Le second identifiant et le nom du helper de recréation changent à
		# chaque release : capturés, jamais codés en dur. Seul CE site est dans
		# une fonction async ; les destroy de fvr (sync) sont inéligibles.
		perl -0pi -e "s/\((${tray_var_re}\.destroy\(\),${tray_var_re}=null,(\w+)=null)\),(\w+)\(!0\)/(\$1,await new Promise(r=>setTimeout(r,250))),\$3(!0)/" \
			"$index_js"
		if grep -qF "await new Promise(r=>setTimeout(r,250))" "$index_js"; then
			echo "  Added DBus cleanup delay after $tray_var.destroy()"
		else
			echo "  WARNING: no destroy site matched — DBus delay NOT applied"
		fi
	fi

	echo 'Tray menu handler patched'
	echo '##############################################################'

	# Skip tray updates during startup (3 second window)
	echo 'Patching nativeTheme handler for startup delay...'
	if ! grep -q '_trayStartTime' "$index_js"; then
		# EXPRESSION, not a statement. In 1.25927.0 these handlers are chained
		# inside a comma expression (`…}),L.nativeTheme.on(`updated`,…)`), where
		# a `let` declaration is a hard SyntaxError — it shipped once as
		# "Unexpected identifier '_trayStartTime'" and the app would not start.
		# An assignment to globalThis is valid both there and at statement
		# position, so it stays safe whichever shape upstream emits.
		# `\(?` : 1.32885.1 enveloppe aussi cette arrow — `on(\`updated\`,(()=>{`.
		sed -i -E \
			"s/(${electron_var_re}\.nativeTheme\.on\(\s*${Q}updated${Q}\s*,\s*\(?\(\)\s*=>\s*\{)/(globalThis._trayStartTime=Date.now()),\1/g" \
			"$index_js"
		# Callee may be dotted now (`(g.c(),fd(),…)` where older bundles had a
		# bare `(c(),fd(),…)`), otherwise the guard is never actually applied
		# and the variable above ends up dead.
		# POSIX ERE: `\w` is NOT a word class INSIDE a bracket expression —
		# `[\w.]` would match a literal backslash, `w` or `.` and silently fail
		# to match `g.c`. Use the character class, not the escape.
		sed -i -E \
			"s/\(([[:alnum:]_.]+\([^)]*\))\s*,\s*${tray_func_re}\(\)\s*,/(\1,Date.now()-globalThis._trayStartTime>3e3\&\&${tray_func}(),/g" \
			"$index_js"
		echo '  Added startup delay check (3 second window)'
	fi
	echo '##############################################################'
}

patch_tray_icon_selection() {
	echo 'Patching tray icon selection for Linux visibility...'
	local index_js="$main_bundle"
	local dark_check="${electron_var_re}.nativeTheme.shouldUseDarkColors"

	if grep -qP ":\\\$?\w+=${Q}TrayIconTemplate\.png${Q}" "$index_js"; then
		sed -i -E \
			"s/:(\\\$?\w+)=${Q}TrayIconTemplate\.png${Q}/:\1=${dark_check}?\"TrayIconTemplate-Dark.png\":\"TrayIconTemplate.png\"/g" \
			"$index_js"
		echo 'Patched tray icon selection for Linux theme support'
	else
		echo 'Tray icon selection pattern not found or already patched'
	fi
	echo '##############################################################'
}

patch_menu_bar_default() {
	echo 'Patching menuBarEnabled to default to true when unset...'
	local index_js="$main_bundle"

	# 1.25927.0 turned `const e=At("menuBarEnabled")` into
	# `let e=x.n(`menuBarEnabled`)`: const -> let, and the getter became a member
	# call. Accept any declarator and a dotted callee.
	# NB: the `,!!VAR)` coercion this patch rewrites has been absent since at
	# least 1.24012.11, so the no-op branch below is the expected outcome; the
	# extraction is kept only so real drift is still reported rather than masked.
	local menu_bar_var
	menu_bar_var=$(grep -oP \
		"(?:const|let|var) \K\w+(?=\s*=\s*[\w.]+\(${Q}menuBarEnabled${Q}\))" \
		"$index_js" | head -1)
	if [[ -z $menu_bar_var ]]; then
		echo '  Could not extract menuBarEnabled variable name'
		echo '##############################################################'
		return
	fi
	echo "  Found menuBarEnabled variable: $menu_bar_var"

	# Change !!var to var!==false so undefined defaults to true
	if grep -qP ",\s*!!${menu_bar_var}\s*\)" "$index_js"; then
		sed -i -E \
			"s/,\s*!!${menu_bar_var}\s*\)/,${menu_bar_var}!==false)/g" \
			"$index_js"
		echo '  Patched menuBarEnabled to default to true'
	else
		echo '  menuBarEnabled pattern not found or already patched'
	fi
	echo '##############################################################'
}

patch_quick_window() {
	local index_js="$main_bundle"
	# Prepend blur() before a STANDALONE e.hide() (quick-entry submit fix).
	# Anchor on a statement boundary ([;{>]) so the replacement can never land
	# inside an expression like `const r=await e.hide()` — splicing a comma there
	# would create a second, initializer-less const declarator and break the
	# whole bundle (SyntaxError: Missing initializer in const declaration -> the
	# main process throws on load and no window is ever created). On bundles
	# where the quick-entry pattern has drifted away (e.g. 1.11187.x, where the
	# only e.hide() is unrelated origin-validation code) this safely no-ops.
	if grep -q 'e.blur(),e.hide()' "$index_js"; then
		echo '  Quick-window blur already patched'
	elif grep -qE '[;{>]e\.hide\(\)' "$index_js"; then
		sed -i 's/\([;{>]\)e\.hide()/\1e.blur(),e.hide()/g' "$index_js"
		echo 'Added blur() call to fix quick window submit issue'
	else
		echo '  Quick-window standalone e.hide() not found - skipping blur patch'
	fi
}

patch_linux_claude_code() {
	# As of 1.25927.0 upstream getHostPlatform ships the Linux branch itself:
	#   if(process.platform===`win32`)return e===`arm64`?`win32-arm64`:`win32-x64`;
	#   if(process.platform===`linux`)return e===`arm64`?`linux-arm64`:`linux-x64`;
	# so there is nothing left to inject. The helper also moved out of the tray
	# bundle into its own chunk, hence find_chunk rather than $main_bundle.
	# Kept as a sentinel instead of deleted: if Anthropic ever drops the Linux
	# branch again the patch is still here and re-applies.
	echo 'Checking Linux claude code binary support...'
	local index_js
	if index_js=$(find_chunk \
		"process\.platform===${Q}linux${Q}\)return \w+===${Q}arm64${Q}\?${Q}linux-arm64${Q}"); then
		echo "  Already provided upstream in ${index_js#"$build_dir"/} — nothing to patch"
		return
	fi

	# Upstream Linux support absent: fall back to injecting it, next to the
	# win32 branch of getHostPlatform.
	if index_js=$(find_chunk \
		"if\(process\.platform===${Q}win32${Q}\)return \w+===${Q}arm64${Q}\?${Q}win32-arm64${Q}:${Q}win32-x64${Q};throw"); then
		perl -0pi -e "s/if\(process\.platform===(${Q})win32\\1\)return (\w+)===(${Q})arm64\\3\?(${Q})win32-arm64\\4:(${Q})win32-x64\\5;throw/if(process.platform===\"win32\")return \$2===\"arm64\"?\"win32-arm64\":\"win32-x64\";if(process.platform===\"linux\")return \$2===\"arm64\"?\"linux-arm64\":\"linux-x64\";throw/" \
			"$index_js"
		echo "  Added linux claude code support in ${index_js#"$build_dir"/}"
	elif index_js=$(find_chunk "if\(process\.platform===${Q}win32${Q}\)return${Q}win32-x64${Q};"); then
		perl -0pi -e "s/if\(process\.platform===(${Q})win32\\1\)return(${Q})win32-x64\\2;/if(process.platform===\"win32\")return\"win32-x64\";if(process.platform===\"linux\")return process.arch===\"arm64\"?\"linux-arm64\":\"linux-x64\";/" \
			"$index_js"
		echo "  Added linux claude code support, legacy format, in ${index_js#"$build_dir"/}"
	else
		echo '  WARNING: no getHostPlatform pattern found, and no upstream Linux branch'
	fi
}

patch_cowork_linux() {
	echo 'Patching Cowork mode for Linux...'

	if ! find_chunk "${Q}vmClient \(TypeScript\)${Q}" >/dev/null; then
		echo '  Cowork mode code not found in this version, skipping'
		echo '##############################################################'
		return
	fi

	# Until 1.24012.11 every cowork anchor lived in the same chunk as the tray
	# code, so this ran against a single $main_bundle. 1.25927.0 scattered them:
	# vmClient/socket/manifest/retry in one chunk, the availability gate in an
	# index2 chunk. Hand node the whole candidate list and let each sub-patch
	# find its own file; a sub-patch that matches nowhere is what raises a
	# warning now, not one that misses in a given file.
	#
	# All complex patches are done via node to avoid shell escaping issues
	# with minified JavaScript. Uses unique string anchors and dynamic
	# variable extraction to be version-agnostic per CLAUDE.md guidelines.
	cowork_changed_list="$(mktemp -t cowork-changed-XXXXXX)"
	if ! INDEX_LIST="$(main_chunks)" SVC_PATH="cowork-vm-service.js" \
		CHANGED_LIST="$cowork_changed_list" \
		node << 'COWORK_PATCH'
const fs = require('fs');
const files = (process.env.INDEX_LIST || '').split('\n').filter(Boolean);
const changedFiles = [];
let patchCount = 0;

// Since 1.25927.0 the minifier emits template literals, so `"linux"` in one
// release is `` `linux` `` in the next. Q matches either quote character; \Q1
// style backreferences keep an opening quote paired with its own closing one.
// Only the MATCHING side needs this — replacements can keep emitting double
// quotes, which stay valid JS either way.
const Q = '["`]';
// Build a RegExp from a template where {} marks a quote character. Each {}
// pair is independent, matching how the minifier may mix styles.
// CAUTION: the substitution is a blind split on the two characters `{}`, so a
// pattern that needs a literal {} of its own — `[^{}]`, `\{\}` — comes out
// silently corrupted. Build those with `new RegExp(... + Q + ...)` by hand.
// Quantifiers are safe: `{0,200}` and `{40}` contain no empty brace pair.
function re(pattern, flags) {
    return new RegExp(pattern.split('{}').join(Q), flags);
}
// Same idea for literal substring probes: returns a RegExp, not a string.
function lit(s, flags) {
    const escaped = s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return new RegExp(escaped.split('"').join(Q), flags);
}
// Index of the first match of a RegExp, or -1 — the quote-agnostic
// replacement for String.indexOf on a fixed anchor.
function idxOf(str, rx) {
    const m = str.match(rx);
    return m ? m.index : -1;
}

// Sub-patches report into this: a name recorded here matched in at least one
// file, so no warning is emitted for it at the end.
const applied = new Set();

// Is the `return {status:…unsupportedCode:CODE}` carrying CODE guarded by a
// win32 test? Upstream progressively scoped these gates to Windows itself
// (both the MSIX and the build-number one by 1.25927.0), which makes our
// patches no-ops rather than failures — but only when the guard is real.
// Looks at the guard ONLY: everything before the `return` that precedes CODE,
// so a win32 comparison sitting inside the returned object (or in an unrelated
// neighbouring statement) cannot be mistaken for the gate.
function returnGuardedByWin32(code, codeValue, window = 600) {
    const idx = idxOf(code, re('unsupportedCode:{}' + codeValue + '{}'));
    if (idx === -1) return null;               // gate absent entirely
    const back = code.substring(Math.max(0, idx - window), idx);
    const retPos = back.lastIndexOf('return');
    const guard = retPos === -1 ? back : back.substring(0, retPos);
    return /win32/.test(guard.slice(-200));
}

// Helper: extract a balanced block starting at a delimiter.
// Returns the substring from open to close (inclusive), or null.
// Works for {} [] () by specifying the open char.
function extractBlock(str, startIdx, open = '{') {
    const close = { '{': '}', '[': ']', '(': ')' }[open];
    const blockStart = str.indexOf(open, startIdx);
    if (blockStart === -1) return null;
    let depth = 1;
    let pos = blockStart + 1;
    while (depth > 0 && pos < str.length) {
        if (str[pos] === open) depth++;
        else if (str[pos] === close) depth--;
        pos++;
    }
    return depth === 0 ? str.substring(blockStart, pos) : null;
}

for (const indexJs of files) {
let code = fs.readFileSync(indexJs, 'utf8');
const fileOrig = code;

// ============================================================
// Patch 1: Platform check - allow Linux through fz()
// Pattern: VAR!=="darwin"&&VAR!=="win32" (unique in platform gate)
// Anchor: appears near 'unsupported_platform' code value
// ============================================================
const platformGateRe = re('(\\w+)(\\s*!==\\s*{}darwin{}\\s*&&\\s*)\\1(\\s*!==\\s*{}win32{})', 'g');
const origCode = code;
code = code.replace(platformGateRe, (match, varName, mid, end) => {
    // Only patch the instance near the "unsupported_platform" code value
    const matchIdx = origCode.indexOf(match);
    const nearbyText = origCode.substring(matchIdx, matchIdx + 200);
    if (nearbyText.includes('unsupported_platform') || nearbyText.includes('Unsupported platform')) {
        return `${varName}${mid}${varName}${end}&&${varName}!=="linux"`;
    }
    return match;
});
if (code !== origCode) {
    console.log(`  Patched platform check to allow Linux (${indexJs})`);
    applied.add('platform-gate');
    patchCount++;
} else {
    // Try without backreference (in case minifier uses different var names)
    const simpleRe = re('(!=={}darwin{}\\s*&&\\s*\\w+\\s*!=={}win32{})([\\s\\S]{0,200}unsupported_platform)');
    const simpleMatch = code.match(simpleRe);
    if (simpleMatch) {
        const varMatch = simpleMatch[0].match(re('(\\w+)\\s*!==\\s*{}win32{}'));
        if (varMatch) {
            code = code.replace(simpleMatch[1],
                simpleMatch[1] + '&&' + varMatch[1] + '!=="linux"');
            console.log(`  Patched platform check to allow Linux, fallback (${indexJs})`);
            applied.add('platform-gate');
            patchCount++;
        }
    }
}
// Patch 1b (Claude 1.13576.0+): the crashing platform gate was refactored
// upstream into graceful per-capability availability checks of the form
//   process.platform!=="darwin"&&process.platform!=="win32"?{status:"unavailable"}:...
// (e.g. f3i -> "quietPenguin"/Cowork availability, p3i). No single startup
// gate or platform throw remains, so allow Linux through each availability
// check instead. The trailing ?{status:"unavailable"} keeps this targeted to
// real capability gates (and makes the replacement idempotent).
// (1.25927.0) This gate moved out of the cowork chunk into an index2 chunk,
// which is why the file list matters — resolving one bundle would miss it.
const availGateRe = re('(process\\.platform!=={}darwin{}&&process\\.platform!=={}win32{})(\\?\\{status:{}unavailable{}\\})', 'g');
let availGateCount = 0;
code = code.replace(availGateRe, (m, gate, tail) => {
    availGateCount++;
    return gate + '&&process.platform!=="linux"' + tail;
});
if (availGateCount > 0) {
    console.log(`  Patched ${availGateCount} availability platform gate(s) to allow Linux (${indexJs})`);
    applied.add('platform-gate');
    patchCount++;
}

// ============================================================
// Patch 2: Module loading - use TypeScript VM client on Linux
// Anchor: stable string "vmClient (TypeScript)"
// (Claude 1.13576.0+) The old WIN32VAR?"vmClient (TypeScript)" ternary was
// refactored into a loader of the form:
//   function d_t(){return tu()?(...,sG={vm:qti},...):null}
// where the gate tu() resolves windowsStore/appPath and returns false on
// Linux, so the module never loads. Allow Linux through the loader's gate
// call. The minified loader/gate names (d_t/tu) change between releases, so
// anchor on the stable log string and walk back to the enclosing
// `function NAME(){return GATE()?` to stay version-robust.
// ============================================================
// (1.25927.0) The loader body is unchanged apart from the minifier's quote
// style and fresh identifier names — which is exactly why the anchor walks
// back from the log string instead of hardcoding names.
const vmStrIdx = idxOf(code, lit('"vmClient (TypeScript)"'));
if (vmStrIdx !== -1) {
    applied.add('vmclient-anchor');
    const backRegion = code.substring(Math.max(0, vmStrIdx - 400), vmStrIdx);
    const loaderRe = /function (\w+)\(\)\{return ([\w.]+)\(\)\?/g;
    let lm, lastLoader = null;
    while ((lm = loaderRe.exec(backRegion)) !== null) {
        lastLoader = lm;
    }
    if (lastLoader) {
        const loaderFn = lastLoader[1];
        const gateFn = lastLoader[2];
        const orig = `function ${loaderFn}(){return ${gateFn}()?`;
        const repl = `function ${loaderFn}(){return (${gateFn}()||process.platform==="linux")?`;
        if (code.includes(repl)) {
            console.log('  VM client loader gate already patched for Linux');
            applied.add('vmclient-loader');
        } else if (code.includes(orig)) {
            code = code.replace(orig, repl);
            console.log(`  Patched vmClient (TypeScript) loader gate ${loaderFn}/${gateFn} for Linux`);
            applied.add('vmclient-loader');
            patchCount++;
        } else {
            console.log('  WARNING: vmClient loader gate shape changed; not patched');
        }
    } else {
        console.log('  WARNING: Could not find vmClient loader function for module loading patch');
    }
}

// ============================================================
// Patch 3: Socket path - use Unix domain socket on Linux
// Anchor: unique string "cowork-vm-service" in pipe path
// ============================================================
// Group 3 captures the quote character and group 4 the body, so the Windows
// branch is re-emitted with the exact literal the minifier produced. The body
// class excludes BOTH quote styles, which keeps the match from running past
// the end of the literal.
const pipeMatch = code.match(
    /(\w+)(\s*=\s*)(["`])([^"`]*\\\\[^"`]*cowork-vm-service[^"`]*)\3/);
if (pipeMatch) {
    const pipeVar = pipeMatch[1];
    const assign = pipeMatch[2];
    const quote = pipeMatch[3];
    const pipeStr = pipeMatch[4];
    const oldExpr = pipeVar + assign + quote + pipeStr + quote;
    const newExpr = pipeVar + assign +
        'process.platform==="linux"?' +
        '(process.env.XDG_RUNTIME_DIR||"/tmp")+"/cowork-vm-service.sock"' +
        ':' + quote + pipeStr + quote;
    code = code.replace(oldExpr, newExpr);
    console.log(`  Patched socket path for Linux Unix domain socket (${indexJs})`);
    applied.add('socket-path');
    patchCount++;
}

// ============================================================
// Patch 4: Bundle manifest - add empty Linux entries to files
// The linux key MUST exist to prevent TypeError when the app
// accesses files["linux"]["x64"] during cowork status checks.
// Empty arrays mean no VM files are downloaded — this is correct
// because the VM backend is non-functional on Linux (bwrap is
// the only working backend and doesn't use VM files).
// Note: [].every() returns true (vacuous truth), so bO() reports
// "Ready" status. This is intentional — it skips the download.
// ============================================================
// Scoped to the file that actually carries the VM bundle manifest. Without
// this guard the loop would run a bare `sha:"<40 hex>"` match against every
// main-process chunk and splice a bogus linux entry into the first unrelated
// object that happened to look like one.
// Anchored on the VM bundle manifest itself — `sha:"<40 hex>",files:{unix:…`
// with rootfs.img/vmlinuz entries. NOT on claude.exe.zst: that belongs to the
// separate Claude CLI manifest, which since 1.25927.0 lives in different chunks
// entirely (index.chunk-BywqeFiU / index2.chunk-DX4R1ESx) from the VM one.
// 1.32885.1 a doublement changé la donne : un champ `publishedAt:\`date\``
// s'est inséré entre `sha:` et `files:` (l'ancre historique sha→files<200ch
// ne matche plus), et le chunk porte un HISTORIQUE de manifests — 6 blocs
// `files:{unix:…,win32:…}`, pas un seul. On ancre donc directement sur
// `files:{unix:` et on complète CHAQUE bloc dépourvu de clé linux, en
// itérant de la fin vers le début pour que les insertions ne décalent pas
// les offsets restants. Garde-fou de scoping : le fichier doit porter les
// entrées rootfs.img/vmlinuz du manifest VM (jamais le manifest CLI
// claude.exe.zst, qui vit dans d'autres chunks).
const isManifestChunk = /rootfs\.img/.test(code) &&
    re('files\\s*:\\s*\\{\\s*unix\\s*:').test(code);
if (isManifestChunk) {
    const filesRe = new RegExp('files\\s*:\\s*\\{\\s*unix\\s*:', 'g');
    const sites = [];
    let fm;
    while ((fm = filesRe.exec(code)) !== null) sites.push(fm.index);
    let added = 0, present = 0;
    for (const site of sites.reverse()) {
        const braceIdx = code.indexOf('{', site);
        const filesBlock = extractBlock(code, braceIdx, '{');
        if (!filesBlock) continue;
        if (/[,{]\s*(['"`]?)linux\1\s*:\s*\{/.test(filesBlock)) { present++; continue; }
        const insertPos = braceIdx + filesBlock.length - 1;
        code = code.substring(0, insertPos) +
            ',linux:{x64:[],arm64:[]}' + code.substring(insertPos);
        added++;
    }
    if (added > 0) {
        console.log(`  Added empty Linux entries to ${added} bundle` +
            ` manifest(s), VM download disabled (${indexJs})`);
        applied.add('bundle-manifest');
        patchCount++;
    } else if (present > 0) {
        // Manifest already carries a linux key (upstream or a previous run).
        applied.add('bundle-manifest');
    }
}

// ============================================================
// Patch 5: MSIX and Windows build checks only apply on Windows
// Claude 1.13576.0 evaluates the Cowork Windows bundle path on Linux, then
// unconditionally runs the MSIX detector and Windows build detector. On Linux
// this reports msix_required or unsupported_os_version before the Linux backend
// can run. Keep those checks for real Windows installs and skip them elsewhere.
// ============================================================
{
    const msixGateRe = re(
        'if\\(!(\\w+)\\(\\)\\)return\\{status:{}unsupported{},reason:(\\w+)\\(\\)\\.formatMessage\\(\\{defaultMessage:{}Cowork requires Claude Desktop be installed with our modern installer{},id:{}[^"`]+{}\\}\\),unsupportedCode:{}msix_required{}\\};');
    const msixGateMatch = code.match(msixGateRe);
    if (msixGateMatch) {
        code = code.replace(
            msixGateRe,
            (match, detector) => match.replace(
                `if(!${detector}())`,
                `if(process.platform==="win32"&&!${detector}())`
            )
        );
        console.log(`  Patched MSIX installer gate to apply only on win32 (${indexJs})`);
        applied.add('msix-gate');
        patchCount++;
    } else {
        // (1.25927.0) Upstream now writes the gate as
        //   if(t===`win32`&&!r.u())return{…unsupportedCode:`msix_required`}
        // i.e. already scoped to Windows, so there is nothing to gate.
        const guarded = returnGuardedByWin32(code, 'msix_required');
        if (guarded === true) {
            console.log('  MSIX installer gate already win32-scoped upstream');
            applied.add('msix-gate');
        } else if (guarded === false) {
            console.log('  WARNING: Found msix_required but MSIX gate shape changed');
        }
    }

    const windowsBuildGateRe = re(
        'const (\\w+)=19041;\\{const\\{patch:(\\w+)\\}=(\\w+)\\(\\);if\\(\\2===void 0\\|\\|\\2<\\1\\)return\\{status:{}unsupported{},reason:(\\w+)\\(\\)\\.formatMessage\\(\\{defaultMessage:{}Cowork requires Windows 10 build 2004 or later\\. Update your operating system to use this feature\\.{},id:{}[^"`]+{}\\}\\),unsupportedCode:{}unsupported_os_version{}\\}\\}');
    if (windowsBuildGateRe.test(code)) {
        code = code.replace(
            windowsBuildGateRe,
            match => `if(process.platform==="win32"){${match}}`
        );
        console.log(`  Patched Windows build gate to apply only on win32 (${indexJs})`);
        applied.add('winbuild-gate');
        patchCount++;
    } else {
        // Upstream wraps the build check in `if(t===`win32`){…19041…}` itself —
        // already true in 1.24012.11, still true in 1.25927.0.
        const guarded = returnGuardedByWin32(code, 'unsupported_os_version');
        if (guarded === true) {
            console.log('  Windows build gate already win32-scoped upstream');
            applied.add('winbuild-gate');
        } else if (guarded === false) {
            console.log('  WARNING: Found unsupported_os_version but Windows build gate shape changed');
        }
    }
}

// ============================================================
// Patch 6: Auto-launch service daemon on first connection attempt
// Anchor: unique string "VM service not running. The service failed to start."
//
// The retry loop only retries on ENOENT (socket missing). On Linux,
// stale sockets from a previous session give ECONNREFUSED instead,
// which causes an immediate throw with no retry or auto-launch.
//
// Fix: patch the ENOENT check to also match ECONNREFUSED on Linux,
// then inject auto-launch before the retry delay.
// ============================================================
const serviceErrorStr = 'VM service not running. The service failed to start.';
const serviceErrorIdx = code.indexOf(serviceErrorStr);
if (serviceErrorIdx !== -1) {
    applied.add('autolaunch');
    // Step 1: Find the ENOENT check and expand it to include ECONNREFUSED
    // Pattern: VAR.code==="ENOENT"
    // Search backwards from the error string to find it
    const searchStart = Math.max(0, serviceErrorIdx - 300);
    const beforeRegion = code.substring(searchStart, serviceErrorIdx);
    // (1.25927.0) The check is no longer a bare `VAR.code==="ENOENT"`. It now
    // reads `(e instanceof Error&&`code`in e?e.code:void 0)===`ENOENT``, so the
    // comparison's left side is a parenthesised expression. Capture that whole
    // expression and reuse it verbatim for the ECONNREFUSED arm, which keeps
    // this working whichever of the two shapes upstream emits.
    const enoentRe = re(
        '(\\([^()]*(?:\\([^()]*\\)[^()]*)*\\)|[\\w.]+)\\s*===\\s*{}ENOENT{}', 'g');
    let enoentMatch;
    let lastEnoent = null;
    while ((enoentMatch = enoentRe.exec(beforeRegion)) !== null) {
        lastEnoent = enoentMatch;
    }
    if (lastEnoent) {
        const enoentStr = lastEnoent[0];
        const errExpr = lastEnoent[1];
        const enoentAbsIdx = searchStart + lastEnoent.index;
        // Replace: EXPR==="ENOENT"
        // With:    (EXPR==="ENOENT"||process.platform==="linux"&&EXPR==="ECONNREFUSED")
        const expanded =
            '(' + enoentStr +
            '||process.platform==="linux"&&' + errExpr + '==="ECONNREFUSED")';
        code = code.substring(0, enoentAbsIdx) +
            expanded +
            code.substring(enoentAbsIdx + enoentStr.length);
        console.log('  Expanded ENOENT check to include ECONNREFUSED on Linux');
    } else {
        console.log('  WARNING: Could not find ENOENT check for ECONNREFUSED expansion');
    }

    // Step 2: Inject auto-launch before the retry delay
    // Re-find serviceErrorStr since indices shifted after step 1
    const newServiceErrorIdx = code.indexOf(serviceErrorStr);
    const searchEnd = Math.min(code.length, newServiceErrorIdx + 300);
    const searchRegion = code.substring(newServiceErrorIdx, searchEnd);
    // (Claude 1.13576.0+) the inline `await new Promise(r=>setTimeout(r,N))`
    // retry delay was refactored into a helper call `await fa(xti)`. Prefer the
    // old inline form for back-compat, else match the first awaited helper call
    // (with an argument) after the service-error string — that is the retry
    // delay we inject the auto-launch in front of.
    // (1.25927.0) `await pn(xsn)` became `await S.l(_a)` — the helper is reached
    // through a member expression now, which `(\w+)` cannot match.
    const retryMatch = searchRegion.match(
        /await new Promise\((\w+)=>\s*setTimeout\(\1,\s*(\w+)\)\)/
    ) || searchRegion.match(/await ([\w.]+)\((\w+)\)/);
    if (retryMatch) {
        const retryStr = retryMatch[0];
        const retryOffset = searchRegion.indexOf(retryStr);
        const retryAbsIdx = newServiceErrorIdx + retryOffset;
        // Inject auto-launch before the retry delay
        // Service script is in app.asar.unpacked/ (not inside asar, since
        // child_process cannot execute scripts from inside an asar).
        // Uses fork() instead of spawn() because process.execPath in Electron
        // is the Electron binary - spawn would trigger "file open" handling
        // instead of executing the script as Node.js.
        const svcPath = process.env.SVC_PATH || 'cowork-vm-service.js';
        // Extract the enclosing function name (Ma or whatever it's
        // minified to) so the dedup guard attaches to it
        const funcSearchStart = Math.max(0, newServiceErrorIdx - 2000);
        const funcRegion = code.substring(funcSearchStart, newServiceErrorIdx);
        // The function is defined as: async function NAME(t,e){...for(let r=0;r<=LIMIT;r++)
        const funcNameRe = /async function (\w+)\s*\(\s*\w+\s*,\s*\w+\s*\)\s*\{[\s\S]*?for\s*\(\s*let/g;
        let funcMatch;
        let retryFuncName = null;
        while ((funcMatch = funcNameRe.exec(funcRegion)) !== null) {
            retryFuncName = funcMatch[1];
        }
        const svcLaunchedGuard = retryFuncName
            ? retryFuncName + '._svcLaunched'
            : 'globalThis._coworkSvcLaunched';
        const autoLaunch =
            'process.platform==="linux"&&!' + svcLaunchedGuard + '&&(' + svcLaunchedGuard + '=true,' +
            '(()=>{try{' +
            'const _d=require("path").join(process.resourcesPath,' +
            '"app.asar.unpacked","' + svcPath + '");' +
            'if(require("fs").existsSync(_d)){' +
            'const _c=require("child_process").fork(_d,[],' +
            '{detached:true,stdio:"ignore",env:{...process.env,' +
            'ELECTRON_RUN_AS_NODE:"1"}});_c.unref()}' +
            '}catch(_e){console.error("[cowork-autolaunch]",_e)}})()),';
        code = code.substring(0, retryAbsIdx) +
            autoLaunch + code.substring(retryAbsIdx);
        console.log('  Added service daemon auto-launch on Linux');
        patchCount++;
    } else {
        console.log('  WARNING: Could not find retry delay for auto-launch patch');
    }
}

// ============================================================
// Patch 7: Skip Windows-specific smol-bin.vhdx copy on Linux
// The code already checks: if(process.platform==="win32")
// No change needed - win32-gated code is skipped on Linux.
// ============================================================

// ============================================================
// Patch 8: VM download tmpdir fix for Linux
// On Linux, os.tmpdir() returns /tmp which is often a small
// tmpfs (3-4GB). The VM rootfs download decompresses to ~9GB,
// causing ENOSPC. Patch to use the bundle directory (on real
// disk) instead of tmpfs for the download temp files.
// Anchor: unique string "wvm-" in mkdtemp call
// Strategy: find the bundle dir variable from nearby mkdir(),
// then replace tmpdir() with that variable in the mkdtemp call.
// ============================================================
{
    // Find: MKDTEMP(PATH.join(OS.tmpdir(), "wvm-"))
    // The bundle dir var is used in mkdir(VAR, ...) just before
    const mkdtempRe = re('(\\w+)\\.mkdtemp\\(\\s*(\\w+)\\.join\\(\\s*(\\w+)\\.tmpdir\\(\\)\\s*,\\s*{}wvm-{}\\s*\\)\\s*\\)');
    const mkdtempMatch = code.match(mkdtempRe);
    if (mkdtempMatch) {
        const [fullMatch, fsVar, pathVar, osVar] = mkdtempMatch;
        // Find the bundle dir variable: mkdir(VAR, { recursive before wvm-
        const mkdtempIdx = code.indexOf(fullMatch);
        const searchStart = Math.max(0, mkdtempIdx - 2000);
        const before = code.substring(searchStart, mkdtempIdx);
        // Look for: mkdir(VARNAME, { recursive
        const mkdirRe = /(\w+)\.mkdir\(\s*(\w+)\s*,\s*\{\s*recursive/g;
        let bundleVar = null;
        let lastMkdir;
        while ((lastMkdir = mkdirRe.exec(before)) !== null) {
            bundleVar = lastMkdir[2];
        }
        if (bundleVar) {
            // Replace os.tmpdir() with the bundle dir variable
            // On Linux, use the bundle dir; on other platforms keep tmpdir
            const replacement =
                `${fsVar}.mkdtemp(${pathVar}.join(` +
                `process.platform==="linux"?${bundleVar}:${osVar}.tmpdir(),` +
                `"wvm-"))`;
            code = code.substring(0, mkdtempIdx) + replacement +
                code.substring(mkdtempIdx + fullMatch.length);
            console.log(`  Patched VM download temp dir to use bundle path on Linux (${indexJs})`);
            applied.add('tmpdir');
            patchCount++;
        } else {
            console.log('  WARNING: Could not find bundle dir variable for tmpdir patch');
        }
    }
}

// ============================================================
// Patch 9: Copy smol-bin VHDX on Linux
// The win32 block copies smol-bin then calls _.configure()
// (Windows HCS setup) which causes "Request timed out" on
// Linux (#315). Inject a separate Linux block after the win32
// block that only does the smol-bin copy.
// Variable names are extracted dynamically from the win32 block
// since minified names change between releases (#344).
// ============================================================
{
    const anchorRe = lit('"[VM:start] Windows VM service configured"');
    const anchorMatch = code.match(anchorRe);
    const anchorIdx = anchorMatch ? anchorMatch.index : -1;
    if (anchorIdx !== -1) {
        applied.add('smol-bin');
        const anchor = anchorMatch[0];
        // Find the "}" closing the win32 if-block after the anchor
        const closingBrace = code.indexOf('}', anchorIdx + anchor.length);
        if (closingBrace !== -1) {
            // Extract minified variable names from the win32 block
            // Search backwards from anchor to find the win32 block.
            // 1000 chars was enough while the block sat in the single main
            // bundle; after the 1.25927.0 split the resourcesPath/existsSync/
            // pipeline references sit further back, so widen the window.
            const regionStart = Math.max(0, anchorIdx - 4000);
            const region = code.substring(regionStart, anchorIdx);

            // (1.25927.0) Three shape changes at once here:
            //  - members are dotted now (`a.Fi.info` for 1.24012.11's `he.info`)
            //  - `const` became `let`
            //  - calls go through the indirect form `(0,v.join)(…)` instead of
            //    `v.join(…)`, which no plain `VAR.join` pattern can match
            // `call` matches either call form and captures the callee object.
            const call = (member) =>
                `(?:\\(0,\\s*([\\w.]+)\\.${member}\\)|([\\w.]+)\\.${member})`;
            // Either alternative may be the one that matched, hence the || pair.
            const pick = (m) => m && (m[1] || m[2]);

            // path var: PATH.join(process.resourcesPath,
            const pathMatch = region.match(
                new RegExp(call('join') + '\\(\\s*process\\.resourcesPath\\s*,')
            );
            // fs var: FS.existsSync(
            const fsMatch = region.match(new RegExp(call('existsSync') + '\\('));
            // logger var: LOG.info("[VM:start]
            const logMatch = region.match(
                new RegExp(call('info') + '\\(\\s*[`"]\\[VM:start\\]')
            );
            // stream/pipeline var: STREAM.pipeline(
            const streamMatch = region.match(new RegExp(call('pipeline') + '\\('));
            // arch function: let VAR=FUNC(), used in smol-bin
            const archMatch = region.match(
                new RegExp('(?:const|let|var)\\s+(\\w+)\\s*=\\s*([\\w.]+)\\(\\)\\s*,\\s*\\w+\\s*=\\s*'
                    + call('join'))
            );
            // bundlePath var: PATH.join(VAR,"smol-bin.vhdx")
            const bundleMatch = region.match(
                new RegExp(call('join') + '\\(\\s*(\\w+)\\s*,\\s*'
                    + Q + 'smol-bin\\.vhdx' + Q + '\\s*\\)')
            );

            if (pathMatch && fsMatch && logMatch &&
                streamMatch && archMatch && bundleMatch) {
                // call() contributes two alternatives per callee, so read them
                // through pick(); bundleVar is the group that follows them.
                const pathVar = pick(pathMatch);
                const fsVar = pick(fsMatch);
                const logVar = pick(logMatch);
                const streamVar = pick(streamMatch);
                const archFunc = archMatch[2];
                const bundleVar = bundleMatch[3];

                const linuxBlock =
                    'if(process.platform==="linux"){' +
                    'const _la=' + archFunc + '(),' +
                    '_ls=' + pathVar + '.join(process.resourcesPath,' +
                        '`smol-bin.${_la}.vhdx`),' +
                    '_ld=' + pathVar + '.join(' + bundleVar +
                        ',"smol-bin.vhdx");' +
                    fsVar + '.existsSync(_ls)?' +
                    '(' + logVar + '.info(' +
                        '`[VM:start] Copying smol-bin.${_la}' +
                        '.vhdx to bundle (Linux)`),' +
                    'await ' + streamVar + '.pipeline(' +
                        fsVar + '.createReadStream(_ls),' +
                        fsVar + '.createWriteStream(_ld)),' +
                    logVar + '.info(' +
                        '`[VM:start] smol-bin.${_la}' +
                        '.vhdx copied successfully`))' +
                    ':' + logVar + '.warn(' +
                        '`[VM:start] smol-bin.${_la}' +
                        '.vhdx not found at ${_ls}`)' +
                    '}';
                code = code.substring(0, closingBrace + 1) +
                    linuxBlock +
                    code.substring(closingBrace + 1);
                console.log(`  Injected Linux smol-bin copy block, skips _.configure (${indexJs})`);
                console.log(`    vars: path=${pathVar} fs=${fsVar} log=${logVar} stream=${streamVar} arch=${archFunc} bundle=${bundleVar}`);
                applied.add('smol-bin-injected');
                patchCount++;
            } else {
                const missing = [];
                if (!pathMatch) missing.push('path');
                if (!fsMatch) missing.push('fs');
                if (!logMatch) missing.push('logger');
                if (!streamMatch) missing.push('stream');
                if (!archMatch) missing.push('arch');
                if (!bundleMatch) missing.push('bundlePath');
                console.log(`  WARNING: Could not extract minified variable(s): ${missing.join(', ')}`);
            }
        } else {
            console.log('  WARNING: Could not find closing brace after Windows VM service anchor');
        }
    }
}

// ============================================================
// Patch 8: Spoof anthropic-client-os-platform header to win32
// Server-side Cowork gate rejects non-Windows clients regardless
// of local MSIX patches. Override the header value sent on every
// API request. Anchor: literal header name (unique).
// ============================================================
const osHeaderRe = re('(\\w+)\\.set\\({}anthropic-client-os-platform{},\\s*\\w+\\)', 'g');
let osHeaderMatches = 0;
code = code.replace(osHeaderRe, (match, headerVar) => {
    osHeaderMatches++;
    return `${headerVar}.set("anthropic-client-os-platform","win32")`;
});
// Claude 1.17377.2+ builds the header list as an array-of-tuples instead of a
// Map .set() call: ["anthropic-client-os-platform", <expr>] (e.g. ho.platform).
// Rewrite the tuple value to "win32" as well. Anchored on the literal header
// name so the adjacent os-version tuple is left untouched.
const osHeaderTupleRe = re('(\\[{}anthropic-client-os-platform{},\\s*)[\\w.$()]+(\\])', 'g');
code = code.replace(osHeaderTupleRe, (match, pre, post) => {
    osHeaderMatches++;
    return `${pre}"win32"${post}`;
});
if (osHeaderMatches > 0) {
    console.log(`  Patched anthropic-client-os-platform to win32 (${osHeaderMatches} call site${osHeaderMatches > 1 ? 's' : ''} in ${indexJs})`);
    applied.add('os-platform-header');
    patchCount++;
}

// Only rewrite files this pass actually changed — every other main-process
// chunk is read and left byte-identical.
if (code !== fileOrig) {
    fs.writeFileSync(indexJs, code);
    changedFiles.push(indexJs);
}
}

// Hand the exact set of rewritten files to the syntax gate. Grepping for
// marker strings instead would undercount: it misses any chunk whose patch
// left no distinctive literal behind.
if (process.env.CHANGED_LIST) {
    // Trailing newline is REQUIRED: the reader is a `while IFS= read -r`
    // loop, which silently drops the final entry of a file that does not end
    // in one — the gate then reports one chunk fewer than it verified.
    fs.writeFileSync(process.env.CHANGED_LIST, changedFiles.join('\n') + '\n');
}

// A sub-patch is only in trouble when it matched in NO file. Before the
// 1.25927.0 split every anchor shared one bundle, so a miss was reported
// immediately; now a miss in a given chunk is the normal case and only the
// aggregate is meaningful.
const expected = {
    'platform-gate': 'platform/availability gate',
    'vmclient-anchor': 'vmClient (TypeScript) anchor',
    'vmclient-loader': 'vmClient loader gate',
    'socket-path': 'Unix socket path',
    'bundle-manifest': 'Linux bundle manifest entries',
    'autolaunch': 'service daemon auto-launch',
    'os-platform-header': 'anthropic-client-os-platform header',
    'smol-bin': 'smol-bin VHDX anchor',
};
const missing = Object.entries(expected)
    .filter(([k]) => !applied.has(k))
    .map(([, label]) => label);
console.log(`  Applied ${patchCount} cowork patches across ${files.length} chunk(s)`);
if (missing.length) {
    console.log(`  WARNING: never matched anywhere: ${missing.join(', ')}`);
}
if (patchCount < 5) {
    console.log('  WARNING: Some patches failed - Cowork mode may not work');
}
COWORK_PATCH
	then
		echo 'WARNING: Cowork Linux patches failed' >&2
		echo 'Cowork mode may not be available on Linux' >&2
	fi

	echo '##############################################################'
}

install_node_pty() {
	section_header 'Installing node-pty for terminal support'

	local pty_src_dir=''

	if [[ -n $node_pty_dir ]]; then
		# Use pre-built node-pty (e.g. from Nix)
		echo "Using pre-built node-pty from $node_pty_dir"
		pty_src_dir="$node_pty_dir"
	else
		# Build node-pty from npm
		node_pty_build_dir="$work_dir/node-pty-build"
		mkdir -p "$node_pty_build_dir" || exit 1
		cd "$node_pty_build_dir" || exit 1
		echo '{"name":"node-pty-build","version":"1.0.0","private":true}' > package.json

		echo 'Installing node-pty (this compiles native module)...'
		if npm install node-pty 2>&1; then
			echo 'node-pty installed successfully'
			pty_src_dir="$node_pty_build_dir/node_modules/node-pty"
		else
			echo 'Failed to install node-pty - terminal features may not work'
		fi
	fi

	if [[ -n $pty_src_dir && -d $pty_src_dir ]]; then
		echo 'Copying node-pty JavaScript files into app.asar.contents...'
		mkdir -p "$app_staging_dir/app.asar.contents/node_modules/node-pty" || exit 1
		cp -r "$pty_src_dir/lib" \
			"$app_staging_dir/app.asar.contents/node_modules/node-pty/" || exit 1
		cp "$pty_src_dir/package.json" \
			"$app_staging_dir/app.asar.contents/node_modules/node-pty/" || exit 1
		echo 'node-pty JavaScript files copied'
	elif [[ -z $pty_src_dir ]]; then
		echo 'node-pty source directory not set'
	else
		echo "node-pty directory not found: $pty_src_dir"
	fi

	cd "$app_staging_dir" || exit 1
	section_footer 'node-pty installation'
}

finalize_app_asar() {
	"$asar_exec" pack app.asar.contents app.asar || exit 1

	mkdir -p "$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native" || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		"$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js" || exit 1

	# Copy cowork VM service daemon (must be unpacked for child_process.fork)
	echo 'Copying cowork VM service daemon to unpacked directory...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		"$app_staging_dir/app.asar.unpacked/cowork-vm-service.js" || exit 1
	echo 'Cowork VM service daemon copied to unpacked'

	# Copy node-pty native binaries
	local pty_release_dir=''
	if [[ -n $node_pty_dir && -d $node_pty_dir/build/Release ]]; then
		pty_release_dir="$node_pty_dir/build/Release"
	elif [[ -n $node_pty_build_dir && -d $node_pty_build_dir/node_modules/node-pty/build/Release ]]; then
		pty_release_dir="$node_pty_build_dir/node_modules/node-pty/build/Release"
	fi

	if [[ -n $pty_release_dir ]]; then
		echo 'Copying node-pty native binaries to unpacked directory...'
		mkdir -p "$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release" || exit 1
		cp -r "$pty_release_dir/"* \
			"$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release/" || exit 1
		chmod +x "$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release/"* 2>/dev/null || true
		echo 'node-pty native binaries copied'
	else
		echo 'node-pty native binaries not found - terminal features may not work'
	fi
}

#===============================================================================
# Staging Functions
#===============================================================================

stage_electron() {
	echo 'Copying chosen electron installation to staging area...'
	mkdir -p "$app_staging_dir/node_modules/" || exit 1
	local electron_dir_name
	electron_dir_name=$(basename "$chosen_electron_module_path")
	echo "Copying from $chosen_electron_module_path to $app_staging_dir/node_modules/"
	cp -a "$chosen_electron_module_path" "$app_staging_dir/node_modules/" || exit 1

	local staged_electron_bin="$app_staging_dir/node_modules/$electron_dir_name/dist/electron"
	if [[ -f $staged_electron_bin ]]; then
		echo "Setting executable permission on staged Electron binary: $staged_electron_bin"
		chmod +x "$staged_electron_bin" || exit 1
	else
		echo "Warning: Staged Electron binary not found at expected path: $staged_electron_bin"
	fi

	# Copy Electron locale files
	local electron_resources_src="$chosen_electron_module_path/dist/resources"
	electron_resources_dest="$app_staging_dir/node_modules/$electron_dir_name/dist/resources"
	if [[ -d $electron_resources_src ]]; then
		echo 'Copying Electron locale resources...'
		mkdir -p "$electron_resources_dest" || exit 1
		cp -a "$electron_resources_src"/* "$electron_resources_dest/" || exit 1
		echo 'Electron locale resources copied'
	else
		echo "Warning: Electron resources directory not found at $electron_resources_src"
	fi
}

process_icons() {
	section_header 'Icon Processing'

	cd "$claude_extract_dir" || exit 1
	local exe_path='lib/net45/claude.exe'
	if [[ ! -f $exe_path ]]; then
		echo "Cannot find claude.exe at expected path: $claude_extract_dir/$exe_path" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo "Extracting application icons from $exe_path..."
	if ! wrestool -x -t 14 "$exe_path" -o claude.ico; then
		echo 'Failed to extract icons from exe' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if ! icotool -x claude.ico; then
		echo 'Failed to convert icons' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	cp claude_*.png "$work_dir/" || exit 1
	echo "Application icons extracted and copied to $work_dir"

	cd "$project_root" || exit 1

	# Process tray icons
	local claude_locale_src="$claude_extract_dir/lib/net45/resources"
	echo 'Copying and processing tray icon files for Linux...'
	if [[ ! -d $claude_locale_src ]]; then
		echo "Warning: Claude resources directory not found at $claude_locale_src"
		section_footer 'Icon Processing'
		return
	fi

	cp "$claude_locale_src/Tray"* "$electron_resources_dest/" 2>/dev/null || \
		echo 'Warning: No tray icon files found'

	# Find ImageMagick command
	local magick_cmd=''
	command -v magick &> /dev/null && magick_cmd='magick'
	[[ -z $magick_cmd ]] && command -v convert &> /dev/null && magick_cmd='convert'

	if [[ -z $magick_cmd ]]; then
		echo 'Warning: ImageMagick not found - tray icons may appear invisible'
		echo 'Tray icon files copied (unprocessed)'
		section_footer 'Icon Processing'
		return
	fi

	echo "Processing tray icons for Linux visibility (using $magick_cmd)..."
	local icon_file icon_name
	for icon_file in "$electron_resources_dest"/TrayIconTemplate*.png; do
		[[ ! -f $icon_file ]] && continue
		icon_name=$(basename "$icon_file")
		if "$magick_cmd" "$icon_file" -channel A -fx 'a>0?1:0' +channel \
			"PNG32:$icon_file" 2>/dev/null; then
			echo "  Processed $icon_name (100% opaque)"
		else
			echo "  Failed to process $icon_name"
		fi
	done
	echo 'Tray icon files copied and processed'

	section_footer 'Icon Processing'
}

copy_locale_files() {
	local claude_locale_src="$claude_extract_dir/lib/net45/resources"
	echo 'Copying Claude locale JSON files to Electron resources directory...'
	if [[ -d $claude_locale_src ]]; then
		cp "$claude_locale_src/"*-*.json "$electron_resources_dest/" || exit 1
		echo 'Claude locale JSON files copied to Electron resources directory'
	else
		echo "Warning: Claude locale source directory not found at $claude_locale_src"
	fi

	echo "app.asar processed and staged in $app_staging_dir"
}

copy_ssh_helpers() {
	section_header 'SSH Helpers'

	local ssh_src="$claude_extract_dir/lib/net45/resources/claude-ssh"
	local ssh_dest="$electron_resources_dest/claude-ssh"
	local binary_name="claude-ssh-linux-$architecture"

	if [[ ! -d "$ssh_src" ]]; then
		echo "Warning: SSH helpers not found at $ssh_src"
		section_footer 'SSH Helpers'
		return
	fi

	mkdir -p "$ssh_dest" || exit 1
	cp "$ssh_src/version.txt" "$ssh_dest/" || exit 1
	cp "$ssh_src/$binary_name" "$ssh_dest/" || exit 1
	chmod +x "$ssh_dest/$binary_name"

	echo "Copied SSH helper files:"
	echo "  version.txt"
	echo "  $binary_name"

	section_footer 'SSH Helpers'
}

copy_cowork_resources() {
	section_header 'Cowork Resources'

	local resources_src="$claude_extract_dir/lib/net45/resources"

	# Copy cowork-plugin-shim.sh (used by app for MCP plugin sandboxing)
	local shim_src="$resources_src/cowork-plugin-shim.sh"
	if [[ -f $shim_src ]]; then
		cp "$shim_src" "$electron_resources_dest/cowork-plugin-shim.sh"
		chmod +x "$electron_resources_dest/cowork-plugin-shim.sh"
		echo "Copied cowork-plugin-shim.sh"
	else
		echo "Warning: cowork-plugin-shim.sh not found at $shim_src"
	fi

	# Copy smol-bin VHDX (contains SDK binaries for KVM guest VM).
	# The app copies this from resources to the bundle dir at startup
	# (win32-gated; our index.js patch extends this to Linux).
	# App looks for smol-bin.{arch}.vhdx where arch is x64 or arm64.
	local smol_arch='x64'
	if [[ $architecture == 'arm64' ]]; then
		smol_arch='arm64'
	fi
	local smol_vhdx="$resources_src/smol-bin.${smol_arch}.vhdx"
	if [[ -f $smol_vhdx ]]; then
		cp "$smol_vhdx" \
			"$electron_resources_dest/smol-bin.${smol_arch}.vhdx"
		echo "Copied smol-bin.${smol_arch}.vhdx"
	else
		echo "Warning: smol-bin VHDX not found at $smol_vhdx"
		echo "KVM Cowork will rely on virtiofs for SDK access"
	fi

	section_footer 'Cowork Resources'
}

#===============================================================================
# Packaging Functions
#===============================================================================

run_packaging() {
	section_header 'Call Packaging Script'

	if [[ $build_format == 'nix' ]]; then
		echo 'Nix build mode - skipping packaging (Nix derivation handles installation)'
		section_footer 'Call Packaging Script'
		return 0
	fi

	local output_path=''
	local script_name file_pattern pkg_file

	case "$build_format" in
		deb)
			script_name='build-deb-package.sh'
			file_pattern="${PACKAGE_NAME}_${version}_${architecture}.deb"
			;;
		rpm)
			script_name='build-rpm-package.sh'
			file_pattern="${PACKAGE_NAME}-${version}*.rpm"
			;;
		appimage)
			script_name='build-appimage.sh'
			file_pattern="${PACKAGE_NAME}-${version}-${architecture}.AppImage"
			;;
	esac

	if [[ $build_format == 'deb' || $build_format == 'rpm' ]]; then
		echo "Calling ${build_format^^} packaging script for $architecture..."
		chmod +x "scripts/$script_name" || exit 1
		if ! "scripts/$script_name" \
			"$version" "$architecture" "$work_dir" "$app_staging_dir" \
			"$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
			echo "${build_format^^} packaging script failed." >&2
			exit 1
		fi

		pkg_file=$(find "$work_dir" -maxdepth 1 -name "$file_pattern" | head -n 1)
		echo "${build_format^^} Build complete!"
		if [[ -n $pkg_file && -f $pkg_file ]]; then
			output_path="./$(basename "$pkg_file")"
			mv "$pkg_file" "$output_path" || exit 1
			echo "Package created at: $output_path"
		else
			echo "Warning: Could not determine final .${build_format} file path."
			output_path='Not Found'
		fi

	elif [[ $build_format == 'appimage' ]]; then
		echo "Calling AppImage packaging script for $architecture..."
		chmod +x scripts/build-appimage.sh || exit 1
		if ! scripts/build-appimage.sh \
			"$version" "$architecture" "$work_dir" "$app_staging_dir" "$PACKAGE_NAME"; then
			echo 'AppImage packaging script failed.' >&2
			exit 1
		fi

		local appimage_file
		appimage_file=$(find "$work_dir" -maxdepth 1 -name "${PACKAGE_NAME}-${version}-${architecture}.AppImage" | head -n 1)
		echo 'AppImage Build complete!'
		if [[ -n $appimage_file && -f $appimage_file ]]; then
			output_path="./$(basename "$appimage_file")"
			mv "$appimage_file" "$output_path" || exit 1
			echo "Package created at: $output_path"

			section_header 'Generate .desktop file for AppImage'
			local desktop_file="./${PACKAGE_NAME}-appimage.desktop"
			echo "Generating .desktop file for AppImage at $desktop_file..."
			cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $version)
Exec=$(basename "$output_path") %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-AppImage-Version=$version
X-AppImage-Name=Claude Desktop (AppImage)
EOF
			echo '.desktop file generated.'
		else
			echo 'Warning: Could not determine final .AppImage file path.'
			output_path='Not Found'
		fi
	fi

	# Store for print_next_steps
	final_output_path="$output_path"
}

cleanup_build() {
	section_header 'Cleanup'
	if [[ $perform_cleanup != true ]]; then
		echo "Skipping cleanup of intermediate build files in $work_dir."
		return
	fi

	echo "Cleaning up intermediate build files in $work_dir..."
	if rm -rf "$work_dir"; then
		echo "Cleanup complete ($work_dir removed)."
	else
		echo 'Cleanup command failed.'
	fi
}

print_next_steps() {
	echo -e '\n\033[1;34m====== Next Steps ======\033[0m'

	case "$build_format" in
		deb|rpm)
			if [[ $final_output_path != 'Not Found' && -e $final_output_path ]]; then
				local pkg_type install_cmd alt_cmd
				if [[ $build_format == 'deb' ]]; then
					pkg_type='Debian'
					install_cmd="sudo apt install $final_output_path"
					alt_cmd="sudo dpkg -i $final_output_path"
				else
					pkg_type='RPM'
					install_cmd="sudo dnf install $final_output_path"
					alt_cmd="sudo rpm -i $final_output_path"
				fi
				echo -e "To install the $pkg_type package, run:"
				echo -e "   \033[1;32m$install_cmd\033[0m"
				echo -e "   (or \`$alt_cmd\`)"
			else
				echo -e "${build_format^^} package file not found. Cannot provide installation instructions."
			fi
			;;
		appimage)
		if [[ $final_output_path != 'Not Found' && -e $final_output_path ]]; then
			echo -e "AppImage created at: \033[1;36m$final_output_path\033[0m"
			echo -e '\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mGear Lever\033[0m for proper desktop integration'
			# shellcheck disable=SC2016  # backticks intentional for display
		echo -e 'and to handle the `claude://` login process correctly.'
			echo -e '\nTo install Gear Lever:'
			echo -e '   1. Install via Flatpak:'
			echo -e '      \033[1;32mflatpak install flathub it.mijorus.gearlever\033[0m'
			echo -e '   2. Integrate your AppImage with just one click:'
			echo -e '      - Open Gear Lever'
			echo -e "      - Drag and drop \033[1;36m$final_output_path\033[0m into Gear Lever"
			echo -e "      - Click 'Integrate' to add it to your app menu"
			if [[ ${GITHUB_ACTIONS:-} == 'true' ]]; then
				echo -e '\n   This AppImage includes embedded update information!'
			else
				echo -e '\n   This locally-built AppImage does not include update information.'
				echo -e '   For automatic updates, download release versions: https://github.com/aaddrick/claude-desktop-debian/releases'
			fi
		else
			echo -e 'AppImage file not found. Cannot provide usage instructions.'
		fi
			;;
	esac

	echo -e '\033[1;34m======================\033[0m'
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
	# Phase 1: Setup
	detect_architecture
	detect_distro
	check_system_requirements
	parse_arguments "$@"

	# Early exit for test mode
	if [[ $test_flags_mode == true ]]; then
		echo '--- Test Flags Mode Enabled ---'
		echo "Build Format: $build_format"
		echo "Clean Action: $cleanup_action"
		echo 'Exiting without build.'
		exit 0
	fi

	if [[ $build_format != 'nix' ]]; then
		check_dependencies
	fi
	setup_work_directory

	if [[ $build_format != 'nix' ]]; then
		setup_nodejs
		setup_electron_asar
	else
		# Nix provides node and asar in PATH
		asar_exec=$(command -v asar)
		if [[ -z $asar_exec ]]; then
			echo 'Error: asar not found in PATH (expected Nix to provide it)' >&2
			exit 1
		fi
	fi

	# Phase 2: Download and extract
	if [[ $build_format == 'nix' && -z $local_exe_path ]]; then
		echo 'Error: --exe is required when --build nix is specified' >&2
		exit 1
	fi
	download_claude_installer

	# Phase 3: Patch and prepare
	patch_app_asar
	install_node_pty
	finalize_app_asar
	if [[ $build_format != 'nix' ]]; then
		stage_electron
		copy_locale_files
	else
		# Nix installPhase handles Electron staging and locale files.
		# Set a resources destination so process_icons and copy_ssh_helpers
		# have somewhere to write; the Nix installPhase picks them up.
		electron_resources_dest="$app_staging_dir/nix-resources"
		mkdir -p "$electron_resources_dest" || exit 1
	fi
	process_icons
	copy_ssh_helpers
	copy_cowork_resources

	cd "$project_root" || exit 1

	# Phase 4: Package
	run_packaging

	# Phase 5: Cleanup and finish
	cleanup_build

	echo 'Build process finished.'
	if [[ $build_format != 'nix' ]]; then
		print_next_steps
	fi
}

# Run main with all script arguments
main "$@"

exit 0
