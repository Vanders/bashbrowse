#!/bin/bash
#Copyright (c) 2012, Kristian Van Der Vliet
#All rights reserved.
#
#Redistribution and use in source and binary forms, with or without
#modification, are permitted provided that the following conditions are met:
#
#Redistributions of source code must retain the above copyright notice, this
#list of conditions and the following disclaimer.
#Redistributions in binary form must reproduce the above copyright notice,
#this list of conditions and the following disclaimer in the documentation
#and/or other materials provided with the distribution.
#THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
#AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
#IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
#ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
#LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
#CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
#SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
#INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
#CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
#ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
#POSSIBILITY OF SUCH DAMAGE.

# URL currently loaded
URL="http://www.example.com"

# URL with no local resource, used to build relative links
BASE_URL=""

# Current "position" within the document
#
# 0 = Not currently parsing tags
# 1 = html document
# 2 = head
# 3 = body
# 4 = post-body
# 5 = inside a SCRIPT or STYLE tag
# 6 = inside a TITLE tag
SECTION=0

# Previous section (poor mans stack)
PREVIOUS_SECTION=0

# Elements of the last tag we processed
declare -a TAG_ELEMENTS=( )

# Screen size and last known co-ordinates
WIDTH=$(tput cols)
HEIGHT=$(tput lines)
X=0
Y=0

# Store current PS1 as we may screw with it
OLD_PS1=$PS1

# "Stack" to hold each link target as we find them
declare -a LINK_STACK=( )

# Link Stack Pointer
LSP=0

# Flag to enable or disable the native HTTP loader. It's slower, and probably
# quite broken at the moment
NATIVE_LOADER=0

# Enable or disable debug
DEBUG=0

function debug
{
  if (( $DEBUG == 1 ))
  then
    echo $1 >&2
  fi
}

function init
{
  # Reset internal variables
  TAG_ELEMENTS=( )
  LINK_STACK=( )
  LSP=0
  X=0
  Y=0

  # Hide the cursor
  tput civis
  # Clear the screen
  clear
  # Something while it loads
  set_title "Loading $URL..."
}

function fini
{
  # Remove any text decoration in effect
  reset_text
  # Make sure text is visible
  stty echo
  # Display the cursor
  tput cnorm
  # Reset the XTerm title
  set_title "$OLD_PS1"
  # Just for neatness
  printf "\n"
}

function clean_exit
{
  # Done
  fini
  exit 0
}

function load
{
  local url="$1"
  local host=''
  local resource=''
  local response=''
  declare -a headers=( )
  declare -a body=( )
  local rc=0

  debug "url=\"$url\""

  host=$(echo $url | cut -d / -f 3 | sed -e 's#//#/#g')
  resource=$(echo $url | cut -d / -f 4- | sed -e 's#//#/#g')

  debug "host=\"$host\", resource=\"$resource\""

  if [[ ! -z "$host" ]]
  then
    local in_body=0
    local count=0

    debug "loading /$resource from $host"

    # Create a new handle for a socket to the server and send our request
    exec 3<> /dev/tcp/$host/80
    echo -e "GET /$resource HTTP/1.0\r\nHost: $host\r\n\r\n" >&3
    # Read the response
    while read line <&3
    do
      if [[ "$line" == $'\r' && $in_body == 0 ]]
      then
        in_body=1
        count=0
        continue  
      fi

      if (( $in_body ))
      then
        body[$count]=$line
      else
        headers[$count]=$line
      fi
      ((count++))
    done

    # Check the HTTP response
    response_code=$(echo ${headers[0]} | cut -d ' ' -f 2)
    response_error=$(echo ${headers[0]} | cut -d ' ' -f 3-)

    debug "response code=$response_code"
    rc=${response_code:0:1}
    case $rc in
      2)
        debug "2xx response"
        response=$( echo ${body[*]} | tr -d '\n' | tr -d '\r' | tr -d '\b' | tr -d '\033' )
      ;;
      3)
        debug "3xx response"
        count=${#headers[@]}
        cur=0
        while (( $cur < $count ))
        do
          if [[ ! -z $(echo "${headers[$cur]}" | grep -i "Location: ") ]]
          then
            response=$(echo ${headers[$cur]} | cut -d ' ' -f 2 | tr -d '\r' | tr -d '\n')
            break
          fi
          ((cur++))
        done
      ;;
      4|5)
        response="<html><head><title>$response_code $response_error</title></head><body>The requested URL could not be loaded</body></html>"
      ;;
      *)
        debug "Unknown HTTP response code $response_code"
        response="<html><head><title>Unknown error</title></head><body>The requested URL could not be loaded</body></html>"
      ;;
    esac
  else
    response="<html><head><title>404 Not found</title></head><body>The requested URL could not be loaded</body></html>"
    rc=4  # 404
  fi
  # Close the socket
  exec 3>&-

  echo $response
  exit $rc  # We're only ever called as a sub-shell, so we can return a useful return code to the caller
}

function get_cursor
{
  local old_stty=$(stty -g)
  local pos=''

  # Enter raw mode
  stty raw -echo min 0

  # Send "current cursor" sequence and read response
  tput u7 > /dev/tty
  IFS=';' read -r -d R -a pos
  pos=$(echo $pos | sed -e 's/\o033\[//')

  # Reset tty
  stty $old_stty

  # Parse out column (X) & row (Y)
  X=$((${pos[1]} - 1))
  Y=$((${pos[0]} - 1))
}

function set_cursor
{
  tput cup $Y $X
}

function clear_line
{
  printf "\r\033[0K"
}

function set_url
{
  local domain=''

  URL="$1"

  domain=$(echo "$URL" | cut -d '/' -f 3)
  BASE_URL="http://$domain"
}

function read_cmd
{
  local prompt="$1"
  local cmd=''

  stty -echo
  read -e -n 1 -p "$prompt" cmd
  stty echo

  echo $cmd | tr "[A-Z]" "[a-z]"
}

function select_link
{
  local cmd=''
  local target=''
  local link_no=0
  local rc=0

  while (( 1 ))
  do
    target="${LINK_STACK[$link_no]}"
    clear_line
    printf "$target"

    # Get next command
    cmd=$(read_cmd)
    case $cmd in

      'l')
        # Select next link
        ((link_no++))
        if (( $link_no == $LSP ))
        then
          link_no=0
        fi

        continue
      ;;

      ' ')
        set_url "$target"
        rc=1
        break;
      ;;

      *)
        break;
      ;;

    esac
  done

  return $rc
}

function command_wait
{
  local cmd=''
  local do_wait=1
  local rc=0

  printf "\n\n"

  while (( $do_wait ))
  do
    # Wait for input
    clear_line
    cmd=$(read_cmd "Space for next page, l to select a link, r to reload, u to enter new URL or q to quit.")
    case $cmd in

      ' ')
        # Clear the current page and continue parsing from where we stopped
        clear
        do_wait=0
      ;;

      'l')
        select_link
        rc=$?
        if (( $rc ))
        then
          do_wait=0
        fi
      ;;

      'r')
        rc=1
        do_wait=0
      ;;

      'u')
        local new_url=''

        clear_line
        read -e -p "URL: http://" new_url
        if [ ! -z "$new_url" ]
        then
          set_url "http://$new_url"
          rc=1
          do_wait=0
        fi
      ;;

      'q')
        clean_exit
        do_wait=0
      ;;

    esac
  done

  return $rc
}

function push_link
{
  local target="$1"
  
  # Fixup relative links
  if [[ -z "$(echo "$target" | grep "http")" ]]
  then
    if [[ "${target:0:1}" == "/" ]]
    then
      target="$URL$target"
    else
      target="$URL/$target"
    fi
  fi

  LINK_STACK[$LSP]="$target"
  ((LSP++))
}

function set_title
{
  echo -ne "\033]2;$1\007"
}

function reset_text
{
  # Black on white
  echo -ne "\033[0m"
}

function bold_on
{
  echo -ne "\033[1m"
}

function bold_off
{
  reset_text
}

function underline_on
{
  echo -en "\033[4m"
}

function underline_off
{
  reset_text
}

function italics_on
{
  # White on black
  echo -ne "\033[47m\033[30m"
}

function italics_off
{
  reset_text
}

function link_on
{
  # Blue on black
  echo -ne "\033[34m"
}

function link_off
{
  reset_text
}

function image
{
  echo -ne "\033[42m "
  reset_text
}

function input_box
{
  local size=$(echo "$1" | tr -d '"')
  local cols=$WIDTH

  # Only draw to the given size or end of the current row
  get_cursor
  if (( ($size + $X) > $cols ))
  then
    ((cols-=$X))
  else
    cols=$size
  fi

  # Red text
  echo -ne "\033[31m "
  while ((cols--))
  do
    printf "%s" "_"
  done
  reset_text
}

function input
{
  local class=''
  local size=0

  class=$(tag_element "class")
  debug "input class=$class"

  case $class in
    "inputtext")
      size=$(tag_element "size")
      input_box $size 
    ;;
    "password")
      size=$(tag_element "size")
      input_box $size 
    ;;
    "hidden")
    ;;
    "submit")
    ;;
  esac
}

function horizontal_rule
{
  local cols=$WIDTH

  # Only draw to the end of the current row
  get_cursor
  ((cols-=$X))

  while ((cols--))
  do
    printf "%s" "—"
  done
}

function link_target
{
  local target=''

  target=$(tag_element "href")
  echo $target | tr -d '"'
}

function parse_tag
{
  local tag="$1"
  local count=0
  local old_ifs=''

  # Clear any old tag elements
  TAG_ELEMENTS=( )

  # Reset IFS as we've been called from process_page which screws with it
  old_ifs=$IFS
  IFS=" ="
  for el in $tag
  do
    debug "tag element $count=\"$el\""
    TAG_ELEMENTS[$count]=$(echo $el | tr "[A-Z]" "[a-z]")
    ((count++))
  done

  # Restore previous IFS or we'll break page parsing
  IFS=$old_ifs
}

function tag_element
{
  local element="$1"
  local value=''
  local count=${#TAG_ELEMENTS[@]}
  local cur=0

  while (($cur <= $count))
  do
    debug "current tag element=\"${TAG_ELEMENTS[$cur]}\""

    if [[ "${TAG_ELEMENTS[$cur]}" == "$element" ]]
    then
      value=${TAG_ELEMENTS[$cur+1]}
      break
    fi
    ((cur++))
  done

  echo $value | tr "[A-Z]" "[a-z]"
}

function process_markup_tag
{
  local tname="$1"

  debug "markup tag \"$tname\""

  case "$tname" in

    "tr"|"/td"|"div"|"/blockquote"|"span"|"/span")
      # Ignored
    ;;

    "br"|"br/"|"table"|"blockquote"|"/p"|"/tr"|"/div")
      printf "\n"
    ;;

    "p"|"td")
      printf " "
    ;;

    "/table"|"hr")
      horizontal_rule
    ;;

    "a")
      local target=''

      link_on

      target=$(link_target)
      debug "link target=$target"
      push_link "$target"
    ;;

    "/a")
      link_off
    ;;

    "b")
      bold_on
    ;;

    "/b")
      bold_off
    ;;

    "u")
      underline_on
    ;;

    "/u")
      underline_off
    ;;

    "i")
      italics_on
    ;;

    "/i")
      italics_off
    ;;

    "img")
      image
    ;;

    "input")
      input
    ;;

    "textarea")
      input_box $(($WIDTH/2))
    ;;
    *)
      debug "Unknown tag $tname (SECTION=$SECTION)"
    ;;

  esac
}

function process_tag
{
  local tag="$1"
  local tname=''

  parse_tag "$tag"
  tname=$(echo -n ${TAG_ELEMENTS[0]} | tr -d ' ' | tr "[A-Z]" "[a-z]")

  debug "tname=$tname, TAG_ELEMENTS=${#TAG_ELEMENTS[@]}"

  case "$tname" in

    "html")
      debug "html tag, SECTION=1"
      SECTION=1
    ;;

    "head")
      if (( $SECTION == 0 || $SECTION == 1 ))
      then
        debug "head tag, SECTION=2"
        SECTION=2
      fi
    ;;

    "/head")
      if (( $SECTION == 2 ))
      then
        debug "/head tag, SECTION=1"
        SECTION=1
      fi
    ;;

    "body")
      if (( $SECTION == 0 || $SECTION == 1 ))
      then
        debug "body tag, SECTION=3"
        SECTION=3
      fi
    ;;

    "script"|"style")
      # Ignore everything up until the closing tag
      PREVIOUS_SECTION=$SECTION
      SECTION=5
    ;;

    "/script"|"/style")
      SECTION=$PREVIOUS_SECTION
    ;;

    "title")
      if (( $SECTION == 2 ))
      then
        debug "title tag, SECTION=6"
        SECTION=6
      fi
    ;;

    "/title")
      if (( $SECTION == 6 ))
      then
        debug "/title tag, SECTION=2"
        SECTION=2
      fi
    ;;

    "/body")
      if (( $SECTION == 3 ))
      then
        debug "/body tag, SECTION=4"
        SECTION=4
      fi
    ;;

    "/html")
      if (( $SECTION == 4 ))
      then
        debug "/html tag, SECTION=0"
        SECTION=0
      fi
    ;;

    *)
      if (( $SECTION == 3 ))
      then
        process_markup_tag "$tname"
      fi
    ;;

  esac
}

function process_string
{
  local output="$1"
  local rc=0

  if (( $SECTION == 3 || $SECTION == 6 ))
  then
    # Have we reached the bottom of the screen?
    get_cursor
    if (( $Y >= ($HEIGHT-4) ))
    then
      command_wait

      # If command_wait returns 1 (link selected) then stop here
      rc=$?
      if (( $rc ))
      then
        return $rc
      fi
    fi

    # Replace some common embedded characters. Sorry for the regex, but the HTML spec sucks
    # While we're here, there is no way to get Bash to print "real" Unicode characters. You suck, Bash
    output=$(echo $output | sed -e 's/&lt;\?/</g;s/&gt;\?/>/g;s/&nbsp;\?/ /g;s/&amp;\?/\&/g;s/&copy;\?/(C)/g;s/&quot;\?/\"/g;s/&raquo;\?/»/g;s/&bull;\?/•/g;s/&middot;\?/·/g;s/&#0\?39;\?/`/g;s/&#0\?44;\?/,/g')

    case $SECTION in
      3)
        printf "%s" "$output"
      ;;

      6)
        set_title "$output"
      ;;
    esac
  fi

  return $rc
}

function parse_page
{
  local page="$1"
  local line=''
  local old_ifs=''
  local rc=0

  # This is complex.
  #
  # The page is split into lines, the boundary being the start of a new tag ('<'). That gives
  # us a line which starts on a tag: however, that line might be a tag on it's own, or a tag
  # followed by some text. So, we split the line into two parts at the *end* of the tag.
  # That gives us the tag (& it's arguments) and any text following the tag.

  old_ifs=$IFS
  IFS="<"
  for line in $PAGE
  do
    declare -a parts=( )
    local count=0
    local part=''
    local tag=''
    local string=''

    # Split the line into a tag and anything proceeding the tag
    IFS=">"
    for part in $line
    do
      parts[$count]="$part"
      ((count++))
    done

    # The tag must be the first part, the proceeding text (if any) the second
    tag="${parts[0]}"
    string="${parts[1]}"

    debug "tag=$tag"

    # Process the tag
    process_tag "$tag"

    # Display the current string if appropriate
    if [[ "$string" ]]
    then
      process_string "$string"
      rc=$?
      if (( $rc ))
      then
        break
      fi
    fi

  done
  IFS=$old_ifs

  return $rc
}

# Entry point
if [[ "$1" ]]
then
  set_url "$1"
fi

if [[ "$2" == "-d" ]]
then
  DEBUG=1
fi

rc=1

while (( $rc ))
do
  # Setup the terminal
  init

  # Load the page, striping out non-printable characters which will ruin our day
  if (( $NATIVE_LOADER ))
  then
    PAGE=$(load $URL)
    # Was this a redirect?
    if (( $? == 3))
    then
      set_url "$PAGE"
      continue
    fi
  else
    PAGE=$(curl $URL 2>/dev/null | tr -d "\n" | tr -d "\r" | tr -d "\b" | tr -d "\033" )
  fi

  # Parse and and display the page
  parse_page "$PAGE"
  rc=$?

  if (( $rc ))
  then
    continue
  else
    command_wait
    rc=$?
  fi
done

# We fell through from command_wait (user probably hit space) so cleanup & exit
clean_exit

exit 0

