#!/bin/bash
# tui_animated_header - Staged reveal with color cycling
# Part of Ubuntify - Mac Pro Conversion Tool

# Colors (ANSI)
readonly C_RESET='\033[0m'
readonly C_CYAN='\033[0;36m'
readonly C_GREEN='\033[0;32m'
readonly C_MAGENTA='\033[0;35m'
readonly C_WHITE='\033[1;37m'
readonly C_DIM='\033[2m'

# Animation: Staged reveal with color cycling
tui_animated_header() {
    local subtitle="${1:-Mac Pro Conversion and Management Tool}"
    local delay="${2:-0.15}"

    # ASCII art lines
    local -a lines=(
        " _   _ _                 _   _  __       "
        "| | | | |__  _   _ _ __ | |_(_)/ _|_   _ "
        "| | | | '_ \| | | | '_ \| __| | |_| | | |"
        "| _  | |_) | |_| | | | | |_| |  _| |_| |"
        "|_| |_|_.__/ \__,_|_| |_|\__|_|_|  \__, |"
        "                                   |___/ "
    )

    # Calculate widths
    local max_width=0
    for line in "${lines[@]}"; do
        local len=${#line}
        [ "$len" -gt "$max_width" ] && max_width=$len
    done
    local subtitle_len=${#subtitle}
    [ "$subtitle_len" -gt "$max_width" ] && max_width=$subtitle_len
    max_width=$((max_width + 4))
    local dashes=$(printf '%*s' $max_width '')

    # Animation phases
    local -a phases=(
        "$C_DIM"      # Dim start
        "$C_CYAN"     # Cyan
        "$C_CYAN"     # Cyan bright
        "$C_GREEN"    # Green
        "$C_GREEN"    # Green bright
        "$C_MAGENTA"  # Magenta
        "$C_WHITE"    # White steady
    )

    local num_phases=${#phases[@]}
    local num_lines=${#lines[@]}

    # Clear screen area
    printf '\n\n'

    # First pass: dim, staged reveal
    local phase=0
    for i in "${!lines[@]}"; do
        local color="${phases[$phase]}"
        printf "%s│ %s%*s │%s\n" "$color" "${lines[$i]}" $((max_width - ${#lines[$i]})) '' "$C_RESET"
        sleep "$delay"
        phase=$(( (phase + 1) % num_phases ))
    done

    # Subtitle reveal
    local padding=$((max_width - subtitle_len))
    printf "%s│ %s%*s │%s\n" "$C_CYAN" "$subtitle" $padding '' "$C_RESET"

    # Second pass: color cycling (optional - controlled by caller)
    if [ "${3:-1}" -eq 1 ]; then
        sleep 0.3
        for cycle in {1..3}; do
            for color in "$C_CYAN" "$C_GREEN" "$C_MAGENTA" "$C_WHITE"; do
                printf '\033[%dA' $((num_lines + 1))  # Move cursor up
                printf "%s┌─%s─┐%s\n" "$color" "${dashes// /─}" "$C_RESET"
                for j in "${!lines[@]}"; do
                    printf "%s│ %s%*s │%s\n" "$color" "${lines[$j]}" $((max_width - ${#lines[$j]})) '' "$C_RESET"
                done
                printf "%s│ %s%*s │%s\n" "$color" "$subtitle" $padding '' "$C_RESET"
                printf "%s└─%s─┘%s\n" "$color" "${dashes// /─}" "$C_RESET"
                sleep 0.4
            done
        done
        # Final frame - white
        printf '\033[%dA' $((num_lines + 1))
    fi
}

# Simple version (no cycling, single render)
tui_simple_animated_header() {
    local subtitle="${1:-Mac Pro Conversion and Management Tool}"

    local art=$(figlet -f standard "Ubuntify" 2>/dev/null) || art=" _   _ _                 _   _  __       
| | | | |__  _   _ _ __ | |_(_)/ _|_   _ 
| | | | '_ \| | | | '_ \| __| | |_| | | |
|_| |_| |_) | |_| | | | | |_| |  _| |_| |
 \___/|_.__/ \__,_|_| |_|\__|_|_|  \__, |
                                   |___/ "

    local max_width=0
    while IFS= read -r line; do
        local len=${#line}
        [ "$len" -gt "$max_width" ] && max_width=$len
    done <<< "$art"
    local subtitle_len=${#subtitle}
    [ "$subtitle_len" -gt "$max_width" ] && max_width=$subtitle_len
    max_width=$((max_width + 4))
    local dashes=$(printf '%*s' $max_width '')

    echo ""
    echo -e "\033[0;36m┌─${dashes// /─}─┐\033[0m"
    while IFS= read -r line; do
        local len=${#line}
        local padding=$((max_width - len))
        echo -e "\033[0;36m│ \033[1;37m${line}\033[0;36m$(printf '%*s' $padding '')\033[0;36m │\033[0m"
    done <<< "$art"
    local padding=$((max_width - subtitle_len))
    echo -e "\033[0;36m│ \033[1;36m${subtitle}\033[0;36m$(printf '%*s' $padding '')\033[0;36m │\033[0m"
    echo -e "\033[0;36m└─${dashes// /─}─┘\033[0m"
    echo ""
}

# Test if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    clear
    echo "Testing animated header..."
    sleep 1
    tui_simple_animated_header "Mac Pro Conversion and Management Tool"
    echo ""
    echo "Press Enter to see staged reveal..."
    read
    clear
    tui_animated_header "Mac Pro Conversion and Management Tool" 0.2 0
    echo ""
    echo "Done!"
fi