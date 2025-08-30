#!/usr/bin/env bash
# shellcheck disable=SC2155,SC2207,SC2034,SC2004

# CPU Cores Monitor Script for Waybar
# Shows overall CPU usage with detailed per-core breakdown in tooltip

# Configuration
CACHE_FILE="/tmp/waybar_cpu_cores"
MAX_CACHE_AGE=2
DECIMAL_PLACES=1

# Progress bar customization
# You can change these values to customize the appearance:
# BAR_LENGTH: Length of the progress bar (default: 10)
# BAR_FILLED_CHAR: Character for filled portion (examples: "|", "█", "▅", "=", "#", "-")
# BAR_EMPTY_CHAR: Character for empty portion (examples: " ", "░", "▁", "-", ".")
BAR_LENGTH=20
BAR_FILLED_CHAR="|"
BAR_EMPTY_CHAR=" "
TOP_PROCESSES=5

# Check if cache is still valid
if [[ -f "$CACHE_FILE" ]]; then
    cache_age=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)))
    if [[ $cache_age -lt $MAX_CACHE_AGE ]]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

# Function to get CPU usage
get_cpu_usage() {
    # Read /proc/stat twice with 1 second interval
    local stat1=$(cat /proc/stat)
    sleep 1
    local stat2=$(cat /proc/stat)
    
    # Parse overall CPU data (first line starting with 'cpu ')
    local overall1=($(echo "$stat1" | grep '^cpu ' | head -1))
    local overall2=($(echo "$stat2" | grep '^cpu ' | head -1))
    
    # Calculate overall CPU usage
    local total1=$((${overall1[1]} + ${overall1[2]} + ${overall1[3]} + ${overall1[4]} + ${overall1[5]} + ${overall1[6]} + ${overall1[7]}))
    local idle1=${overall1[4]}
    local total2=$((${overall2[1]} + ${overall2[2]} + ${overall2[3]} + ${overall2[4]} + ${overall2[5]} + ${overall2[6]} + ${overall2[7]}))
    local idle2=${overall2[4]}
    
    local total_diff=$((total2 - total1))
    local idle_diff=$((idle2 - idle1))
    local overall_usage=0
    
    if [[ $total_diff -gt 0 ]]; then
        overall_usage=$(( (total_diff - idle_diff) * 100 / total_diff ))
    fi
    
    # Build tooltip with HTML formatting for colors
    local tooltip="<b>CPU Usage Details</b>\n<span color='#666666'>====================</span>\n<span color='#ffffff'>Overall: <span color='#00ff00'>${overall_usage}%</span></span>\n\n<b>Per Core Usage:</b>"
    
    # Calculate per-core usage
    local core_count=$(nproc)
    for ((i=0; i<core_count; i++)); do
        # Parse core data
        local core1_data=($(echo "$stat1" | grep "^cpu$i "))
        local core2_data=($(echo "$stat2" | grep "^cpu$i "))
        
        if [[ ${#core1_data[@]} -ge 8 && ${#core2_data[@]} -ge 8 ]]; then
            local core_total1=$((${core1_data[1]} + ${core1_data[2]} + ${core1_data[3]} + ${core1_data[4]} + ${core1_data[5]} + ${core1_data[6]} + ${core1_data[7]}))
            local core_idle1=${core1_data[4]}
            local core_total2=$((${core2_data[1]} + ${core2_data[2]} + ${core2_data[3]} + ${core2_data[4]} + ${core2_data[5]} + ${core2_data[6]} + ${core2_data[7]}))
            local core_idle2=${core2_data[4]}
            
            local core_total_diff=$((core_total2 - core_total1))
            local core_idle_diff=$((core_idle2 - core_idle1))
            local core_usage=0
            
            if [[ $core_total_diff -gt 0 ]]; then
                core_usage=$(( (core_total_diff - core_idle_diff) * 100 / core_total_diff ))
            fi
            
            # Create progress bar with configurable length
            local bar_length=$BAR_LENGTH
            local filled=$((core_usage * bar_length / 100))
            local bar=""
            
            # Ensure at least one block is shown for non-zero usage
            if [[ $core_usage -gt 0 && $filled -eq 0 ]]; then
                filled=1
            fi
            
            # Create colored progress bar with HTML
            local bar=""
            local bar_color="#ff0000"  # Default red for high usage
            
            # Choose color based on usage
            if [[ $core_usage -ge 80 ]]; then
                bar_color="#ff4444"  # Red for high usage
            elif [[ $core_usage -ge 50 ]]; then
                bar_color="#ffaa00"  # Orange for medium usage
            elif [[ $core_usage -ge 20 ]]; then
                bar_color="#ffff00"  # Yellow for low-medium usage
            else
                bar_color="#00ff00"  # Green for low usage
            fi
            
            # Create progress bar using configurable characters
            local bar=""
            for ((j=0; j<filled; j++)); do bar+="$BAR_FILLED_CHAR"; done
            for ((j=filled; j<bar_length; j++)); do bar+="$BAR_EMPTY_CHAR"; done
            
            # Get frequency for this core
            local core_freq=""
            local freq_color="#cccccc"
            if [[ -f "/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_cur_freq" ]]; then
                local cur_freq_khz=$(cat "/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_cur_freq" 2>/dev/null)
                local max_freq_khz=$(cat "/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq" 2>/dev/null)
                
                if [[ -n "$cur_freq_khz" && -n "$max_freq_khz" ]]; then
                    local cur_ghz=$(echo "scale=2; $cur_freq_khz / 1000000" | bc -l 2>/dev/null || echo "0")
                    
                    # Color based on frequency percentage
                    local freq_percent=$(echo "scale=0; $cur_freq_khz * 100 / $max_freq_khz" | bc -l 2>/dev/null || echo "0")
                    if [[ $freq_percent -gt 80 ]]; then
                        freq_color="#ff4444"  # Red for high frequency
                    elif [[ $freq_percent -gt 50 ]]; then
                        freq_color="#ffaa00"  # Orange for medium frequency
                    else
                        freq_color="#00ff00"  # Green for low frequency
                    fi
                    
                    core_freq="${cur_ghz}GHz"
                fi
            fi
            
            # Format with fixed width for better alignment
            local core_num=$(printf "%2d" $i)
            local usage_text=$(printf "%3d%%" $core_usage)
            local freq_text=""
            if [[ -n "$core_freq" ]]; then
                freq_text=$(printf "%2s" "$core_freq")  # Fixed width for frequency
            else
                freq_text="  "  # spaces for alignment
            fi
            
            tooltip+="\n  <span color='#888888'>${core_num}:</span> <span color='${bar_color}'>${bar:0:$filled}</span><span color='#333333'>${bar:$filled}</span> <span color='${bar_color}'>${usage_text}</span> <span color='${freq_color}'>${freq_text}</span>"
        fi
    done
    
    # Add load average with colors
    local load_avg=$(cat /proc/loadavg | cut -d' ' -f1-3)
    tooltip+="\n\n<span color='#cccccc'>Load Average:</span> <span color='#00aaff'>$load_avg</span>"
    
    # Add temperature if available
    if command -v sensors >/dev/null 2>&1; then
        local temp=$(sensors 2>/dev/null | grep -i "core 0" | head -1 | grep -o "[0-9]*\.[0-9]*°C" | head -1)
        if [[ -n "$temp" ]]; then
            # Color temperature based on value
            local temp_num=$(echo "$temp" | grep -o "[0-9]*" | head -1)
            local temp_color="#00ff00"  # Green for cool
            if [[ $temp_num -gt 70 ]]; then
                temp_color="#ff4444"  # Red for hot
            elif [[ $temp_num -gt 50 ]]; then
                temp_color="#ffaa00"  # Orange for warm
            fi
            tooltip+="\n<span color='#cccccc'>Temperature:</span> <span color='${temp_color}'>$temp</span>"
        fi
    fi
    
    # Add CPU frequency information
    if [[ -f /proc/cpuinfo ]]; then
        # Get current frequency from scaling_cur_freq (more accurate than cpuinfo)
        local freq_info=""
        if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
            local cur_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
            local max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
            local min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null)
            
            if [[ -n "$cur_freq" && -n "$max_freq" ]]; then
                # Convert from kHz to GHz
                local cur_ghz=$(echo "scale=2; $cur_freq / 1000000" | bc -l 2>/dev/null || echo "0")
                local max_ghz=$(echo "scale=2; $max_freq / 1000000" | bc -l 2>/dev/null || echo "0")
                local min_ghz=$(echo "scale=2; $min_freq / 1000000" | bc -l 2>/dev/null || echo "0")
                
                # Color frequency based on current vs max
                local freq_color="#00ff00"  # Green for low frequency
                local freq_percent=$(echo "scale=0; $cur_freq * 100 / $max_freq" | bc -l 2>/dev/null || echo "0")
                if [[ $freq_percent -gt 80 ]]; then
                    freq_color="#ff4444"  # Red for high frequency
                elif [[ $freq_percent -gt 50 ]]; then
                    freq_color="#ffaa00"  # Orange for medium frequency
                fi
                
                freq_info="<span color='#cccccc'>Frequency:</span> <span color='${freq_color}'>${cur_ghz}GHz</span> <span color='#666666'>(${min_ghz}-${max_ghz}GHz)</span>"
            fi
        else
            # Fallback to /proc/cpuinfo
            local cpu_mhz=$(grep "cpu MHz" /proc/cpuinfo | head -1 | awk '{print $4}')
            if [[ -n "$cpu_mhz" ]]; then
                local cpu_ghz=$(echo "scale=2; $cpu_mhz / 1000" | bc -l 2>/dev/null || echo "0")
                freq_info="<span color='#cccccc'>Frequency:</span> <span color='#00aaff'>${cpu_ghz}GHz</span>"
            fi
        fi
        
        if [[ -n "$freq_info" ]]; then
            tooltip+="\n$freq_info"
        fi
    fi
    
    # Add top CPU consuming processes
    tooltip+="\n\n<b>Top CPU Processes:</b>"
    local top_processes=$(ps -eo pid,pcpu,comm --sort=-pcpu --no-headers | head -"$TOP_PROCESSES")
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local pid=$(echo "$line" | awk '{print $1}')
            local cpu_percent=$(echo "$line" | awk '{print $2}')
            local process_name=$(echo "$line" | awk '{print $3}' | cut -c1-15)  # Limit name length
            
            # Color based on CPU usage
            local proc_color="#00ff00"  # Green for low usage
            if (( $(echo "$cpu_percent > 20" | bc -l 2>/dev/null || echo 0) )); then
                proc_color="#ffaa00"  # Orange for medium usage
            fi
            if (( $(echo "$cpu_percent > 50" | bc -l 2>/dev/null || echo 0) )); then
                proc_color="#ff4444"  # Red for high usage
            fi
            
            tooltip+="\n  <span color='#888888'>PID ${pid}:</span> <span color='${proc_color}'>${cpu_percent}%</span> <span color='#cccccc'>${process_name}</span>"
        fi
    done <<< "$top_processes"
    
    # Determine CSS class based on usage
    local css_class="cpu-normal"
    if [[ $overall_usage -ge 80 ]]; then
        css_class="cpu-high"
    elif [[ $overall_usage -ge 50 ]]; then
        css_class="cpu-medium"
    fi
    
    # Generate JSON output using printf to handle newlines properly
    local json_output=$(printf '{"text": "%s%%", "tooltip": "%s", "class": "%s", "percentage": %s}' \
        "$overall_usage" "$tooltip" "$css_class" "$overall_usage")
    
    echo "$json_output"
    echo "$json_output" > "$CACHE_FILE"
}

# Fallback function for errors
fallback_output() {
    echo '{"text":" N/A","tooltip":"CPU data unavailable","class":"cpu-error"}'
}

# Main execution with error handling
get_cpu_usage 2>/dev/null || fallback_output
