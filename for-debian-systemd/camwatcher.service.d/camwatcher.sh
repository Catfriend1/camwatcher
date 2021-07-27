#/bin/bash
#
# Command line:
# 	bash "/etc/systemd/system/camwatcher.service.d/camwatcher.sh" cron camera01
# 	bash "/etc/systemd/system/camwatcher.service.d/camwatcher.sh" start camera01
# 	bash "/etc/systemd/system/camwatcher.service.d/camwatcher.sh" stop camera01
# 	watch -n 1 "ps waux | grep camwatcher | grep -v grep"
#
# Service:
# 	systemctl enable camwatcher@camera01
# 	systemctl start camwatcher@camera01
# 	systemctl status camwatcher@camera01
# 	journalctl -f -u camwatcher@camera01
# 	systemctl stop camwatcher@camera01
#
# Prerequisites:
# 	[optional] dvr-scan
# 	apt-get install -y mediainfo
# 	Env vars: Set by camera01.env file
# 		FOLDER_TO_WATCH
# 		INCIDENT_SEND_VIDEO_TO_CHAT
# 		DVRSCAN_EXTRACT_MOTION_ROI
# 		STN_TELEGRAM_BOT_APIKEY
# 		STN_TELEGRAM_BOT_ID
# 		STN_TELEGRAM_CHAT_ID
# 	Get STN_TELEGRAM_CHAT_ID
# 		curl -s "https://api.telegram.org/bot${STN_TELEGRAM_BOT_ID}:${STN_TELEGRAM_BOT_APIKEY}/getUpdates" | grep -o -E '"chat":{"id":[-0-9]*,' | head -n 1
#
# Script Configuration.
FOLDER_MINDEPTH="1"
FILE_DELETE_AFTER_PROCESSING="1"
FILE_WATCH_PATTERN="*.mp4"
SKIP_SENDING_PUSH_MESSAGES="0"
SLEEP_CYCLE_SECONDS="60"
#
# Consts: CFS
## This is used to make the notification message silent if anyone is home while the camera caught motion.
G_DP_PRESENCE_ANYONE="/tmp/cfs/dp/presence/anyone"
#
## Settings: Analyze and delete camera footage which contains false alarms
### Check incoming videos if they really contain motion.
### Delete them if no motion is found.
### ROI x,y,w,h derived from VLC snapshot analyzed in ImageGlass
DVRSCAN_MOTION_ANALYSIS="1"
DVRSCAN_PYTHON="/usr/bin/python3"
DVRSCAN_SCRIPT="/usr/local/bin/dvr-scan"
DVRSCAN_EXTRACT_FORMAT="H264"
DVRSCAN_EXTRACT_MOTION="1"
DVRSCAN_EXTRACT_MOTION_MIN_EVENT_LENGTH="4"				# default: 2
#
DVRSCAN_EXTRACT_MOTION_THRESHOLD="0.4"					# default: 0.15
DVRSCAN_EXTRACT_BEFORE="00:00:01.0000"
DVRSCAN_EXTRACT_AFTER="00:00:03.0000"
###
### For testing purposes only.
#### /usr/local/bin/dvr-scan -i "/tmp/test1.mp4" -o "/tmp/ouput.mp4" -c "H264" -l 4 -roi 339 488 333 591 339 1044 1052 35 -t "0.4" -tb "00:00:03.0000" -tp "00:00:03.0000"
##
### Use ffmpeg to extract jpg series from videos.
FFMPEG_EXTRACT_JPG="1"
FFMPEG_EXTRACT_JPG_SIZE="640x360"
FFMPEG_EXTRACT_DURATION="10"
FFMPEG_EXTRACT_RATE="1"
##
### Check if incoming videos are longer than X seconds.
### Useful for example when Yi Cameras always submit a 59 second video subsequently after
### submitting the short video which contains the motion event.
### Use "0" to forward all video lengths via push notification.
MAX_VIDEO_LENGTH_SECONDS="0"
#
# Runtime Variables.
SCRIPT_FULLFN="$(basename -- "${0}")"
SCRIPT_NAME="${SCRIPT_FULLFN%.*}"
LOGFILE="/tmp/${SCRIPT_NAME}.log"
LOG_MAX_LINES="10000"
#
# -----------------------------------------------------
# -------------- START OF FUNCTION BLOCK --------------
# -----------------------------------------------------
checkFiles ()
{
	#
	# Search for new files.
	if [ -f "/usr/bin/sort" ]; then
		# Default: Optimized for busybox, debian
		L_FILE_LIST="$(find "${FOLDER_TO_WATCH}" -mindepth ${FOLDER_MINDEPTH} -type f \( -name "${FILE_WATCH_PATTERN}" \) | sort -k 1 -n)"
	else
		# Alternative: Unsorted output
		L_FILE_LIST="$(find "${FOLDER_TO_WATCH}" -mindepth ${FOLDER_MINDEPTH} -type f \( -name "${FILE_WATCH_PATTERN}" \))"
	fi
	if [ -z "${L_FILE_LIST}" ]; then
		return 0
	fi
	#
	echo "${L_FILE_LIST}" | while read file; do
		# Only process files that have not been processed by dvrscan before.
		if ( ! echo "${file}" | grep -q "_processed.mp4$" ); then
			if [ ! -s "${file}" ]; then
				echo "[INFO] checkFiles: Skipping empty file [${file}]"
				rm -f "${file}"
				continue
			fi
			#
			if [ "${MAX_VIDEO_LENGTH_SECONDS}" -gt "0" ]; then
				 VIDEO_LENGTH_NS="$(mediainfo --Inform="Video;%Duration%" "${file}")"
				 VIDEO_LENGTH_SECONDS="$((VIDEO_LENGTH_NS/100000000))"
				 if [ "${VIDEO_LENGTH_SECONDS}" -gt "${MAX_VIDEO_LENGTH_SECONDS}" ]; then
					logAdd "[INFO] checkFiles: mediainfo reported [${VIDEO_LENGTH_SECONDS}s] over limit [${MAX_VIDEO_LENGTH_SECONDS}s] - [${file}]. Deleting and skipping."
					rm -f "${file}"
					continue
				 fi
			fi
			#
			if [ "${DVRSCAN_MOTION_ANALYSIS}" = "1" ]; then
				TMP_MOTION_VIDEO="/tmp/dvr-scan-motion_${LOG_SUFFIX}.mp4"
				if ( ! "${DVRSCAN_PYTHON}" "${DVRSCAN_SCRIPT}" -i "${file}" -o "${TMP_MOTION_VIDEO}" -c "${DVRSCAN_EXTRACT_FORMAT}" -l "${DVRSCAN_EXTRACT_MOTION_MIN_EVENT_LENGTH}" ${DVRSCAN_EXTRACT_MOTION_ROI} -t "${DVRSCAN_EXTRACT_MOTION_THRESHOLD}" -tb "${DVRSCAN_EXTRACT_BEFORE}" -tp "${DVRSCAN_EXTRACT_AFTER}" | grep "] Detected" ); then
					logAdd "[INFO] checkFiles: dvr-scan reported no motion - [${file}]. Deleting and skipping."
					if [ "${FILE_DELETE_AFTER_PROCESSING}" = "1" ]; then
						rm -f "${file}"
					fi
					continue
				fi
				#
				if [ "${DVRSCAN_EXTRACT_MOTION}" = "1" ]; then
					rm -f "${file}"
					file="$(echo "${file}" | sed -e "s/.mp4$/_processed.mp4/")"
					if ( ! mv "${TMP_MOTION_VIDEO}" "${file}" ); then
						logAdd "[ERROR] checkFiles: mv out of free disk space. Deleting and skipping."
						continue
					fi
				fi
			fi
		fi
		#
		#
		if [ "${INCIDENT_SEND_VIDEO_TO_CHAT}" = "1" ]; then
			if ( ! sendTelegramNotification -- "${file}" ); then
				logAdd "[ERROR] checkFiles: sendTelegramNotification FAILED - [${file}]."
				continue
			fi
		fi
		logAdd "[INFO] checkFiles: sendTelegramNotification SUCCEEDED - [${file}]."
		#
		if [ "${FFMPEG_EXTRACT_JPG}" = "1" ]; then
			MOTION_SNAPSHOT_DIR="/tmp/motion_snapshot_${LOG_SUFFIX}"
			mkdir -p "${MOTION_SNAPSHOT_DIR}"
			if ( ffmpeg -nostdin -loglevel error -i "${file}" -t "${FFMPEG_EXTRACT_DURATION}" -s "${FFMPEG_EXTRACT_JPG_SIZE}" -r "${FFMPEG_EXTRACT_RATE}" "${MOTION_SNAPSHOT_DIR}/snapshot_%04d.jpg" ); then
				if [ -f "${MOTION_SNAPSHOT_DIR}/snapshot_0002.jpg" ] && [ -f "${MOTION_SNAPSHOT_DIR}/snapshot_0003.jpg" ]; then
					logAdd "[INFO] checkFiles: Uploading JPG snapshots ..."
					INCIDENT_TIMESTAMP="$(echo "${file%%.mp4}" | sed -e "s~${FOLDER_TO_WATCH}/~~" -e "s/[YMDH]/-/g" -e "s/H//" -e "s~/~~" -e "s/_processed//" | sed -E "s/S[0-9]{2}//" | sed -e 's/^\(.\{10\}\)./\1_/')"
					# sendTelegramMediaGroup "${INCIDENT_TIMESTAMP}" "${MOTION_SNAPSHOT_DIR}/snapshot_0002.jpg" "${MOTION_SNAPSHOT_DIR}/snapshot_0003.jpg"
					if ( ! sendTelegramMediaGroup "${INCIDENT_TIMESTAMP}" "${MOTION_SNAPSHOT_DIR}/snapshot_0004.jpg" ); then
						logAdd "[ERROR] checkFiles: sendTelegramMediaGroup jpg snapshot FAILED."
					fi
				fi
				#
				# Alternative
				#for JPG_SNAPSHOT in ${MOTION_SNAPSHOT_DIR}/snapshot_*.jpg ; do
				#	if [ -f "${JPG_SNAPSHOT}" ]; then
				#		if ( ! sendTelegramNotification -- "${JPG_SNAPSHOT}" ); then
				#			logAdd "[ERROR] checkFiles: sendTelegramNotification FAILED - [${JPG_SNAPSHOT}]."
				#		fi
				#	fi
				#done
			fi
			if [ "${FILE_DELETE_AFTER_PROCESSING}" = "1" ] && [ ! -z "${MOTION_SNAPSHOT_DIR}" ]; then
				rm -rf "${MOTION_SNAPSHOT_DIR}"
			fi
		fi
		#
		if [ "${FILE_DELETE_AFTER_PROCESSING}" = "1" ]; then
			rm -f "${file}"
		fi
		#
	done
	#
	# Delete empty sub directories
	if [ ! -z "${FOLDER_TO_WATCH}" ]; then
		find "${FOLDER_TO_WATCH}/" -mindepth 1 -type d -empty -delete
	fi
	#
	return 0
}


logAdd ()
{
	TMP_DATETIME="$(date '+%Y-%m-%d [%H-%M-%S]')"
	TMP_LOGSTREAM="$(tail -n ${LOG_MAX_LINES} ${LOGFILE} 2>/dev/null)"
	echo "${TMP_LOGSTREAM}" > "$LOGFILE"
	echo "${TMP_DATETIME} $*" | tee -a "${LOGFILE}"
	return 0
}


sendTelegramMediaGroup ()
{
	#
	# Usage:			sendTelegramMediaGroup "[TEXT_CAPTION]" "[ATTACHMENT1_FULLFN]" "[ATTACHMENT2_FULLFN]"
	# 					Paramter #2 is optional.
	# Example:			sendTelegramMediaGroup "/tmp/test1.jpg" "/tmp/test2.jpg"
	# Purpose:
	# 	Send push message to Telegram Bot Chat
	#
	# Global Variables
	# 	[IN] STN_TELEGRAM_BOT_ID
	# 	[IN] STN_TELEGRAM_BOT_APIKEY
	# 	[IN] STN_TELEGRAM_CHAT_ID
	#
	# Returns:
	# 	"0" on SUCCESS
	# 	"1" on FAILURE
	#
	# Variables.
	TMP_TEXT_CAPTION="${1}"
	if [ "${SKIP_SENDING_PUSH_MESSAGES}" = "1" ]; then
		logAdd "[INFO] sendTelegramMediaGroup skipped due to SKIP_SENDING_PUSH_MESSAGES == 1."
		return 1
	fi
	#
	# Add first attachment.
	STN_ATT1_FULLFN="${2}"
	if [ ! "${STN_ATT1_FULLFN##*.}" = "jpg" ]; then
		return 1
	fi
	TMP_MEDIA_ARRAY="{\"type\":\"photo\",\"media\":\"attach://photo_1\",\"caption\":\"${TMP_TEXT_CAPTION}\"}"
	TMP_ATTACHMENT_ARRAY="-F "\"photo_1=@${STN_ATT1_FULLFN}\"""
	#
	# Add second attachment if applicable.
	STN_ATT2_FULLFN="${3}"
	if [ ! -z "${STN_ATT2_FULLFN}" ] && [ ! "${STN_ATT2_FULLFN##*.}" = "jpg" ]; then
		return 1
	fi
	if [ ! -z "${STN_ATT2_FULLFN}" ]; then
		TMP_MEDIA_ARRAY="${TMP_MEDIA_ARRAY},{\"type\":\"photo\",\"media\":\"attach://photo_2\",\"caption\":\"\"}"
		TMP_ATTACHMENT_ARRAY="${TMP_ATTACHMENT_ARRAY} -F "\"photo_2=@${STN_ATT2_FULLFN}\"""
	fi
	#
	CURL_RESULT="$(eval curl -q \
			--insecure \
			--max-time \""60\"" \
			-F "media='[${TMP_MEDIA_ARRAY}]'" \
			${TMP_ATTACHMENT_ARRAY} \
			 "\"https://api.telegram.org/bot${STN_TELEGRAM_BOT_ID}:${STN_TELEGRAM_BOT_APIKEY}/sendMediaGroup?chat_id=${STN_TELEGRAM_CHAT_ID}&disable_notification=true\"" \
			 2> /dev/null)"
	if ( ! echo "${CURL_RESULT}" | grep -Fiq "\"ok\":true" ); then
		if ( echo "${CURL_RESULT}" | grep -Fiq "\"error_code\":413," ); then
			logAdd "[ERROR] sendTelegramMediaGroup: Attachment too large. Deleting and skipping."
			rm -f "${STN_ATT1_FULLFN}"
			if [ ! -z "${STN_ATT2_FULLFN}" ]; then
				rm -f "${STN_ATT2_FULLFN}"
			fi
		else
			logAdd "[DEBUG] sendTelegramMediaGroup: API_RESULT=${CURL_RESULT}"
		fi
		return 1
	fi
	#
	# Return SUCCESS.
	return 0
}


sendTelegramNotification ()
{
	#
	# Usage:			sendTelegramNotification "[PN_TEXT]" "[ATTACHMENT_FULLFN]"
	# Example:			sendTelegramNotification "Test push message" "/tmp/test.txt"
	# Purpose:
	# 	Send push message to Telegram Bot Chat
	#
	# Returns:
	# 	"0" on SUCCESS
	# 	"1" on FAILURE
	#
	# Global Variables
	# 	[IN] STN_TELEGRAM_BOT_ID
	# 	[IN] STN_TELEGRAM_BOT_APIKEY
	# 	[IN] STN_TELEGRAM_CHAT_ID
	#
	# Variables.
	STN_TEXT="${1}"
	STN_TEXT="${STN_TEXT//\"/\\\"}"
	STN_ATT_FULLFN="${2}"
	#
	if [ "${STN_TEXT}" = "--" ]; then
		STN_TEXT=""
	fi
	if [ -z "${STN_TEXT}" ] && [ -z "${STN_ATT_FULLFN}" ]; then
		return 1
	fi
	#
	if [ "${SKIP_SENDING_PUSH_MESSAGES}" = "1" ]; then
		logAdd "[INFO] sendTelegramNotification skipped due to SKIP_SENDING_PUSH_MESSAGES == 1."
		return 1
	fi
	#
	# If anyone is home, plan a silent notification.
	STN_DISABLE_NOTIFICATION="false"
	if ( cat "${G_DP_PRESENCE_ANYONE}" 2>/dev/null | grep -Fiq "1" ); then
		STN_DISABLE_NOTIFICATION="true"
	fi
	#
	if [ ! -z "${STN_TEXT}" ]; then
		if ( ! eval curl -q \
				--insecure \
				--max-time \""60\"" \
				 "\"https://api.telegram.org/bot${STN_TELEGRAM_BOT_ID}:${STN_TELEGRAM_BOT_APIKEY}/sendMessage?chat_id=${STN_TELEGRAM_CHAT_ID}&disable_notification=${STN_DISABLE_NOTIFICATION}&text=${STN_TEXT}\"" \
				 2> /dev/null \| grep -Fiq "\"ok\\\":true\"" ); then
			return 1
		fi
	fi
	#
	if [ ! -z "${STN_ATT_FULLFN}" ]; then
		if [ "${STN_ATT_FULLFN##*.}" = "jpg" ]; then
			CURL_RESULT="$(eval curl -q \
					--insecure \
					--max-time \""60\"" \
					-F "\"photo=@${STN_ATT_FULLFN}\"" \
					 "\"https://api.telegram.org/bot${STN_TELEGRAM_BOT_ID}:${STN_TELEGRAM_BOT_APIKEY}/sendPhoto?chat_id=${STN_TELEGRAM_CHAT_ID}&disable_notification=${STN_DISABLE_NOTIFICATION}\"" \
					 2> /dev/null)"
			if ( ! echo "${CURL_RESULT}" | grep -Fiq "\"ok\":true" ); then
				if ( echo "${CURL_RESULT}" | grep -Fiq "\"error_code\":413," ); then
					logAdd "[ERROR] sendTelegramNotification: Attachment too large. Deleting and skipping."
					rm -f "${STN_ATT_FULLFN}"
				else
					logAdd "[DEBUG] sendTelegramNotification: API_RESULT=${CURL_RESULT}"
				fi
				return 1
			fi
		elif [ "${STN_ATT_FULLFN##*.}" = "mp4" ]; then
			CURL_RESULT="$(eval curl -q \
					--insecure \
					--max-time \""60\"" \
					-F "\"video=@${STN_ATT_FULLFN}\"" \
					 "\"https://api.telegram.org/bot${STN_TELEGRAM_BOT_ID}:${STN_TELEGRAM_BOT_APIKEY}/sendVideo?chat_id=${STN_TELEGRAM_CHAT_ID}&disable_notification=${STN_DISABLE_NOTIFICATION}\"" \
					 2> /dev/null)"
			if ( ! echo "${CURL_RESULT}" | grep -Fiq "\"ok\":true" ); then
				if ( echo "${CURL_RESULT}" | grep -Fiq "\"error_code\":413," ); then
					logAdd "[ERROR] sendTelegramNotification: Attachment too large. Deleting and skipping."
					rm -f "${STN_ATT_FULLFN}"
				else
					logAdd "[DEBUG] sendTelegramNotification: API_RESULT=${CURL_RESULT}"
				fi
				return 1
			fi
		else
			# Wrong file extension.
			return 1
		fi
		#
	fi
	#
	# Return SUCCESS.
	return 0
}


serviceMain ()
{
	#
	# Usage:		serviceMain	[--one-shot]
	# Called By:	MAIN
	#
	logAdd "[INFO] === SERVICE START ==="
	# sleep 10
	while (true); do
		# Check if folder exists.
		if [ ! -d "${FOLDER_TO_WATCH}" ]; then 
			mkdir -p "${FOLDER_TO_WATCH}"
		fi
		# 
		# Ensure correct file permissions.
		if ( ! stat -c %a "${FOLDER_TO_WATCH}/" | grep -q "^777$"); then
			logAdd "[WARN] Adjusting folder permissions to 0777 ..."
			chmod -R 0777 "${FOLDER_TO_WATCH}"
		fi
		#
		# logAdd "[INFO] checkFiles S"
		checkFiles
		# logAdd "[INFO] checkFiles E"
		#
		if [ "${1}" = "--one-shot" ]; then
			break
		fi
		#
		sleep ${SLEEP_CYCLE_SECONDS}
	done
	return 0
}
# ---------------------------------------------------
# -------------- END OF FUNCTION BLOCK --------------
# ---------------------------------------------------
#
# Check shell
if [ ! -n "$BASH_VERSION" ]; then
	logAdd "[ERROR] Wrong shell environment, please run with bash."
	exit 99
fi
#
SCRIPT_PATH="$(dirname "$(realpath "${0}")")"
ENVIRONMENT_FILE="${SCRIPT_PATH}/${2}.env"
if [ -z "${2}" ] || [ ! -f "${ENVIRONMENT_FILE}" ]; then
	logAdd "[ERROR] Environment file missing: ENVIRONMENT_FILE=[${ENVIRONMENT_FILE}]. Stop."
	exit 99
fi
source "${ENVIRONMENT_FILE}"
#
if [ -z "${FOLDER_TO_WATCH}" ]; then
	logAdd "[ERROR] Env var not set: FOLDER_TO_WATCH. Stop."
	exit 99
fi
#
if [ -z "${INCIDENT_SEND_VIDEO_TO_CHAT}" ]; then
	logAdd "[ERROR] Env var not set: INCIDENT_SEND_VIDEO_TO_CHAT. Stop."
	exit 99
fi
#
if [ -z "${STN_TELEGRAM_BOT_ID}" ] || [ -z "${STN_TELEGRAM_BOT_APIKEY}" ] || [ -z "${STN_TELEGRAM_CHAT_ID}" ]; then
	logAdd "[ERROR] Telegram bot config env vars missing. Stop."
	exit 99
fi
#
if [ "${#DVRSCAN_EXTRACT_MOTION_ROI_ARRAY[*]}" -eq 0 ]; then
	logAdd "[ERROR] Env var array not set: DVRSCAN_EXTRACT_MOTION_ROI_ARRAY. Stop."
	exit 99
fi
#
# Runtime Variables.
LOG_SUFFIX="$(echo "${FOLDER_TO_WATCH}" | sed -e "s/^.*\///")"
LOGFILE="/tmp/${SCRIPT_NAME}_${LOG_SUFFIX}.log"
#
DVRSCAN_EXTRACT_MOTION_ROI="-roi"
for roi in "${DVRSCAN_EXTRACT_MOTION_ROI_ARRAY[@]}"; do
	DVRSCAN_EXTRACT_MOTION_ROI="${DVRSCAN_EXTRACT_MOTION_ROI} ${roi}"
done
logAdd "[INFO] DVRSCAN_EXTRACT_MOTION_ROI=[${DVRSCAN_EXTRACT_MOTION_ROI}]"
#
# set +m
trap "" SIGHUP
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT
#
# Check if "dvr-scan" is available
if [ "${DVRSCAN_MOTION_ANALYSIS}" = "1" ]; then
	if ( ! "${DVRSCAN_PYTHON}" "${DVRSCAN_SCRIPT}" --version > /dev/null 2>&1 ); then
		logAdd "[WARN] dvr-scan is not installed correctly. Setting DVRSCAN_MOTION_ANALYSIS=0."
		DVRSCAN_MOTION_ANALYSIS="0"
	fi
fi
#
# Check if "ffmpeg" is available
if [ "${FFMPEG_EXTRACT_JPG}" = "1" ]; then
	if ( ! ffmpeg -version > /dev/null 2>&1 ); then
		logAdd "[WARN] ffmpeg is not installed correctly. Install it with 'apt-get install -y ffmpeg'. Setting FFMPEG_EXTRACT_JPG=0 to disable the feature."
		FFMPEG_EXTRACT_JPG="0"
	fi
fi
#
# Check if "mediainfo" is available
if [ "${MAX_VIDEO_LENGTH_SECONDS}" -gt "0" ]; then
	if ( ! mediainfo --version > /dev/null 2>&1 ); then
		logAdd "[WARN] mediainfo is not available. Install it with 'apt-get install -y mediainfo'. Setting MAX_VIDEO_LENGTH_SECONDS=0 to disable the feature."
		MAX_VIDEO_LENGTH_SECONDS="0"
	fi
fi
#
if [ "${1}" = "cron" ]; then
	serviceMain --one-shot
	logAdd "[INFO] === SERVICE STOPPED ==="
	exit 0
elif [ "${1}" = "start" ]; then
	serviceMain &
	#
	# Wait for kill -INT.
	wait
	exit 0
elif [ "${1}" = "stop" ]; then
	ps w | grep -v grep | grep "$(basename -- ${SHELL}) ${0}" | sed 's/ \+/|/g' | sed 's/^|//' | cut -d '|' -f 1 | grep -v "^$$" | while read pidhandle; do
		echo "[INFO] Terminating old service instance [${pidhandle}] ..."
		kill -INT "${pidhandle}"
	done
	#
	# Check if parts of the service are still running.
	if [ "$(ps w | grep -v grep | grep "$(basename -- ${SHELL}) ${0}" | sed 's/ \+/|/g' | sed 's/^|//' | cut -d '|' -f 1 | grep -v "^$$" | wc -l)" -gt 1 ]; then
		logAdd "[ERROR] === SERVICE FAILED TO STOP ==="
		exit 99
	fi
	logAdd "[INFO] === SERVICE STOPPED ==="
	exit 0
fi
#
logAdd "[ERROR] Parameter #1 missing."
logAdd "[INFO] Usage: ${SCRIPT_FULLFN} {cron|start|stop}"
exit 99
