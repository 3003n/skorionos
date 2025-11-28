#!/bin/bash

set -e

source ./manifest

function download_file() {
	local url=$1
	local file=$2
	local max_retries=5
	local retry_count=0
	local base_delay=2
	local download_success=false
	
	while [ $retry_count -lt $max_retries ] && [ "$download_success" = false ]; do
		if [ $retry_count -gt 0 ]; then
			# 计算指数退避延迟时间，增加随机抖动
			local delay=$((base_delay * 2 ** (retry_count - 1) + RANDOM % 2))
			echo "Retry downloading $url, attempt $retry_count/$max_retries after waiting ${delay}s..."
			sleep $delay
		fi
		
		if curl -L "$url" -o "$file"; then
			download_success=true
			echo "Successfully downloaded $url to $file"
		else
			echo "Failed to download $url, retry attempt $retry_count/$max_retries"
			retry_count=$((retry_count + 1))
		fi
	done
	
	if [ "$download_success" = false ]; then
		echo "Failed to download $url after $max_retries attempts"
		return 1
	fi
	
	return 0
}

function download_decky_plugin() {
	local repo=$1
	local decky_plugin_path=$2
	local grep_expression=${3:-".tar.gz"}
	local include_prerelease=${4:-false}

	local temp_decky
	temp_decky=$(mktemp -d)

	if [ -z "$temp_decky" ]; then
		echo "temp_decky is empty"
		return
	fi

	local max_retries=5
	local retry_count=0
	local base_delay=2
	local download_url=""

	# Select API endpoint based on prerelease parameter
	if [ "$include_prerelease" = "true" ]; then
		local git_api_url="https://api.github.com/repos/$repo/releases"
		echo "Fetching latest release (including prerelease) from $repo..."
	else
		local git_api_url="https://api.github.com/repos/$repo/releases/latest"
		echo "Fetching latest stable release from $repo..."
	fi

	while [ $retry_count -lt $max_retries ] && [ -z "$download_url" ]; do
		if [ $retry_count -gt 0 ]; then
			# 计算指数退避延迟时间，增加随机抖动
			local delay=$((base_delay * 2 ** (retry_count - 1) + RANDOM % 2))
			echo "Retry $retry_count/$max_retries for $git_api_url after waiting ${delay}s..."
			sleep $delay
		fi

		# Use different jq expressions based on API type
		if [ "$include_prerelease" = "true" ]; then
			# Sort by published_at and get the latest release (including prerelease)
			download_url=$(curl -s "$git_api_url" | \
				jq -r 'sort_by(.published_at) | reverse | first | .assets[].browser_download_url | select(test("'"$grep_expression"'"))' 2>/dev/null | head -1) || true
		else
			# Get from latest stable release
			download_url=$(curl -s "$git_api_url" | \
				jq -r '.assets[].browser_download_url | select(test("'"$grep_expression"'"))' 2>/dev/null | head -1) || true
		fi

		echo "download_url: $download_url"

		# Check if URL was successfully retrieved
		if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
			echo "Failed to get download URL, retry attempt $retry_count/$max_retries"
			download_url=""
			retry_count=$((retry_count + 1))
		fi
	done

	if [ -z "$download_url" ]; then
		echo "Failed to get download URL after $max_retries attempts"
		rm -rf $temp_decky
		return
	fi

	basename=$(basename $download_url)
	ext=${basename##*.}
	curl -L $download_url -o "${temp_decky}/${basename}"

	if [[ "$ext" == "gz" && "$basename" =~ \.tar\.gz ]]; then
		tar -xzvf "${temp_decky}/${basename}" -C $decky_plugin_path
	elif [ "$ext" == "zip" ]; then
		unzip -o "${temp_decky}/${basename}" -d $decky_plugin_path
	fi

	# delete node_modeules if exists
	rm -rf $decky_plugin_path/*/{node_modules,.git,.vscode}

	rm -rf $temp_decky

	sleep 1
}

function download_decky_loader() {
	local git_api_url="https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases/latest"
	local decky_path=$1
	local decky_file=$2
	local decky_version_file=$3
	local decky_service_file=$4

	# decky
	homebrew_folder="/home/${USERNAME}/homebrew"

	mkdir -p $decky_path

	local max_retries=5
	local retry_count=0
	local base_delay=2
	local decky_release=""

	while [ $retry_count -lt $max_retries ] && [ -z "$decky_release" ]; do
		if [ $retry_count -gt 0 ]; then
			# 计算指数退避延迟时间，增加随机抖动
			local delay=$((base_delay * 2 ** (retry_count - 1) + RANDOM % 2))
			echo "Retry $retry_count/$max_retries for decky loader releases API after waiting ${delay}s..."
			sleep $delay
		fi

		decky_release=$(curl -s 'https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases' | jq -r "first(.[])")

		if [ -z "$decky_release" ]; then
			echo "Failed to get decky release, retry attempt $retry_count/$max_retries"
			retry_count=$((retry_count + 1))
		fi
	done

	if [ -z "$decky_release" ]; then
		echo "Failed to get decky release after $max_retries attempts"
		return 1
	fi

	# 提取版本和下载URL
	decky_version=$(jq -r '.tag_name' <<<${decky_release})
	decky_download_url=$(jq -r '.assets[].browser_download_url | select(endswith("PluginLoader"))' <<<${decky_release})

	# 下载文件
	curl -L $decky_download_url --output $decky_file
	echo $decky_version >$decky_version_file

	curl -sL https://raw.githubusercontent.com/SteamDeckHomebrew/decky-loader/main/dist/plugin_loader-release.service -o $decky_service_file
    sed -i -e "s|\${HOMEBREW_FOLDER}|${homebrew_folder}|" $decky_service_file
}

all_download() {

	echo "pre download start"

	pre_download_dir=pre-download
	pre_file_base=sk-pre
    
	pre_path=$pre_download_dir/$pre_file_base

	decky_path=$pre_path/decky
	decky_file=$decky_path/PluginLoader
	decky_version_file=$decky_path/.loader.version
    decky_service_file=$decky_path/plugin_loader.service

	decky_plugin_path=$pre_path/decky-plugins
	css_path=$pre_path/css
	css_hhd_path=$pre_path/css-hhd
	zsh_path=$pre_path/zsh
	refind_path=$pre_path/refind
	rime_config_path=$pre_path/rime_config

    archive_file=$pre_file_base.tar.gz

	# pre download decky
	mkdir -p $decky_path
	download_decky_loader $decky_path $decky_file $decky_version_file $decky_service_file

	# pre download decky plugins
	mkdir -p $decky_plugin_path

	# SDH-CssLoader
	download_decky_plugin "DeckThemes/SDH-CssLoader" $decky_plugin_path "SDH-CSSLoader-Decky.zip"

	# HHD-Decky
	download_decky_plugin "honjow/hhd-decky" $decky_plugin_path

	# PowerControl
	download_decky_plugin "mengmeet/PowerControl" $decky_plugin_path

	# HueSync
	download_decky_plugin "honjow/HueSync" $decky_plugin_path

	# ToMoon
	# download_decky_plugin "YukiCoco/ToMoon" $decky_plugin_path "tomoon.*\.zip"

	# chenx-dust/DeckyClash
	download_decky_plugin "chenx-dust/DeckyClash" $decky_plugin_path "DeckyClash-full.zip"

	# GPD-WinControl
	download_decky_plugin "honjow/GPD-WinControl" $decky_plugin_path

	# decky-sk-box
	download_decky_plugin "honjow/decky-sk-box" $decky_plugin_path

	# aarron-lee/DeckyPlumber
	download_decky_plugin "aarron-lee/DeckyPlumber" $decky_plugin_path

	# honjow/decky-terminal
	download_decky_plugin "honjow/decky-terminal" $decky_plugin_path

	# CheatDeck
	download_decky_plugin "SheffeyG/CheatDeck" $decky_plugin_path ".zip"

	# aarron-lee/LegionGoRemapper
	# download_decky_plugin "aarron-lee/LegionGoRemapper" $decky_plugin_path

	# xXJSONDeruloXx/Decky-Framegen
	download_decky_plugin "xXJSONDeruloXx/Decky-Framegen" $decky_plugin_path "Framegen.zip" true

	# xXJSONDeruloXx/decky-lsfg-vk
	# download_decky_plugin "xXJSONDeruloXx/decky-lsfg-vk" $decky_plugin_path ".zip" true

	# honjow/decky-wine-cellar
	download_decky_plugin "honjow/decky-wine-cellar" $decky_plugin_path ".zip"

	# honjow/decky-natpierce
	# download_decky_plugin "honjow/decky-natpierce" $decky_plugin_path ".zip"

	# chenx-dust/BetterKeyboard
	download_decky_plugin "chenx-dust/BetterKeyboard" $decky_plugin_path ".zip"

	# honjow/MangoPeel
	# download_decky_plugin "honjow/MangoPeel" $decky_plugin_path ".zip"

	# GedasFX/decky-ludusavi
	download_decky_plugin "GedasFX/decky-ludusavi" $decky_plugin_path ".zip"

	# pre download css themes

	# pre download hhd css themes
	mkdir -p $css_hhd_path

	# SBP-Legion-Go-Theme
	# git_url="https://github.com/frazse/SBP-Legion-Go-Theme.git"
	# if [ -d $css_hhd_path/SBP-Legion-Go-Theme ]; then
	# 	rm -rf $css_hhd_path/SBP-Legion-Go-Theme
	# fi
	# git clone --depth 1 $git_url $css_hhd_path/SBP-Legion-Go-Theme
	# echo '{"active": true, "Apply": "Legion-Go-Theme"}' >$css_hhd_path/SBP-Legion-Go-Theme/config_USER.json

	# PSBP-PS5-to-Handheld
	# git_url="https://github.com/honjow/SBP-PS5-to-Handheld.git"
	# if [ -d $css_hhd_path/SBP-PS5-to-Handheld ]; then
	# 	rm -rf $css_hhd_path/SBP-PS5-to-Handheld
	# fi
	# git clone --depth 1 $git_url $css_hhd_path/SBP-PS5-to-Handheld

	# handheld-controller-glyphs
	git_url="https://github.com/honjow/handheld-controller-glyphs.git"
	if [ -d $css_hhd_path/handheld-controller-glyphs-sk ]; then
		rm -rf $css_hhd_path/handheld-controller-glyphs-sk
	fi
	git clone --depth 1 $git_url $css_hhd_path/handheld-controller-glyphs-sk
	rm -rf $css_hhd_path/handheld-controller-glyphs-sk/{.git,.gitignore}

	# pre download rime config
	rime_git_url="https://github.com/iDvel/rime-ice.git"
	if [ -d $rime_config_path ]; then
		rm -rf $rime_config_path
	fi
	git clone --depth 1 $rime_git_url $rime_config_path

	# zsh pre download
	mkdir -p "${zsh_path:?}"
	rm -rf "${zsh_path:?}"/*
	git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "${zsh_path:?}/ohmyzsh"
	git clone --depth 1 https://github.com/zdharma-continuum/fast-syntax-highlighting "${zsh_path:?}/ohmyzsh/custom/plugins/fast-syntax-highlighting"
	cp $zsh_path/ohmyzsh/templates/zshrc.zsh-template $zsh_path/.zshrc
	# add for kitty ssh
	cat >>$zsh_path/.zshrc <<-'EOM'
		[ "$TERM" = "xterm-kitty" ] && alias ssh="kitty +kitten ssh"
	EOM

	# set zsh theme
	sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="ys"/g' $zsh_path/.zshrc
	sed -i 's/plugins=(git)/plugins=(git sudo z fast-syntax-highlighting)/g' $zsh_path/.zshrc
	cat >>$zsh_path/.zshrc <<-'EOM'

		######## skorionos functions ########
		# yazi
		function y() {
		    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
		    yazi "$@" --cwd-file="$tmp"
		    if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
		    builtin cd -- "$cwd"
		    fi
		    rm -f -- "$tmp"
		}
		function sy() {
		    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
		    sudo yazi "$@" --cwd-file="$tmp"
		    if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
		    builtin cd -- "$cwd"
		    fi
		    rm -f -- "$tmp"
		}
		######## skorionos functions end ########

	EOM

	# pre download refind themes
	mkdir -p $refind_path
	git clone --depth 1 "https://github.com/bobafetthotmail/refind-theme-regular.git" $refind_path/refind-theme-regular
	rm -rf $refind_path/refind-theme-regular/{.git,.gitignore,src,install.sh,README.md}

	# UniversalAMDFormBrowser
	download_file "https://github.com/DavidS95/Smokeless_UMAF/raw/main/UniversalAMDFormBrowser.zip" "$pre_path/UMAF.zip"

	# efi drivers
	efi_drivers_path=$pre_path/efi-drivers
	mkdir -p $efi_drivers_path
	download_file "https://github.com/SkorionOS/UsbXbox360Dxe/releases/latest/download/UsbXbox360Dxe.efi" "$efi_drivers_path/UsbXbox360Dxe.efi"


	cd $pre_download_dir
	# find . -type d -name ".git" -exec rm -rf {} \;

    tar -czvf $archive_file $pre_file_base

    rm -rf $pre_file_base

	cd ..

	echo "pre download end"
}


main() {
    all_download
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	set -x
    main "$@"
fi
