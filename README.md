# camwatcher
camwatcher is a bash script systemd service to process mp4 videos from IP cameras and check if there was something useful recorded or just "leaves in the wind". If there's something useful, a Telegram push notification will be sent to a pre-defined group chat.

# Verified working with
- YI camera 1080p S/N BFUSY31
- Debian 10 (buster) amd64

# How to step-by-step to get you started

I've just decided to contribute a script I have created to run on a Linux box that 100% fits the YI camera use case. The script can be run on Debian/Ubuntu/... based linux distros, raspberry pi and more. I'm using it with a Debian box to further analyze the "lot" content my YI cameras record and only send important motion detections to my Telegram group where my family members can se the alerts as JPG images and MP4 videos. The MP4 videos are also cutted down to only contain 3 seconds before the motion event, the event itself and 3 seconds after the motion event. If I'm away from my house and only have poor mobile connection to check the footage, I can look at the JPG image the script posted to the chat which is a lot less mobile data consumption than downloading the video footage.

The script can be setup in an environment like this - just to show you the prerequisites.

(Camera, SDCARD, captures mp4 video files)
==> (WiFi, transfers the mp4 videos via FTP port 21)
==> Debian box (a server running vsftpd/proftpd which processes the videos and filters out relevant motion events to forward them to Telegram)
==> (Internet connection, to reach the Telegram API servers)

Required hardware:
- The YI camera: e.g. Yi Home 1080p BFUSY31 model running yi-hack
- Some debian box: e. g. Raspberry PI or a linux desktop/laptop running Debian amd64
- WiFi router: Your camera needs a local network connection and should be able to reach the debian box on FTP port 21.

Required camera configuration:
- Turn on "Record without cloud"
- Turn on "Save video on motion detection"
- Turn on FTP upload
- (optional) Turn on "delete video files after upload" because my script is intended to do real-time video footage processing.
- Enter FTP server credentials
- Reboot the camera to apply the changes and start uploading footage on motion detection.

Required debian server box configuration:
- Setup vsftpd (or proftpd) to accept the video footage captured by the camera in a defined folder.
- Install packages required to run the video processing script: dvr-scan, mediainfo, python3 (... more info in the script and when you start it the script will tell what packages are missing and need to be installed).
- Download the script to the /etc/systemd/system/ folder, including the subfolder from the repo.

Sources:
```
https://github.com/Catfriend1/camwatcher/blob/main/for-debian-systemdv
https://github.com/Catfriend1/camwatcher/blob/main/for-debian-systemd/camwatcher.service.d/camwatcher.sh
https://github.com/Catfriend1/camwatcher/blob/main/for-debian-systemd/camwatcher@.service
```

- Fill in required config variables: camwatcher.service.d/camera01.env
```
FOLDER_TO_WATCH="/srv/vsftpd-data/camera01"
#
INCIDENT_SEND_VIDEO_TO_CHAT="1"
# 
## Telegram Bot
STN_TELEGRAM_BOT_ID="TO_FILL__TELEGRAM_BOT_ID"
STN_TELEGRAM_BOT_APIKEY="TO_FILL__TELEGRAM_BOT_APIKEY"
#
## Chat ID
### G-Camera-01
STN_TELEGRAM_CHAT_ID="TO_FILL__TELEGRAM_CHAT_ID"
```
(Experts can also configure ROI, but I'd suggest you do it later when everything is set-up and worked fine in the default setup. With ROI, you can select parts of the camera's screen to trigger notifications, this is useful, if you have a street within the view of the camera and do not like every car passing by to trigger a notification on your phone.)
- Your Telegram bot can be created by following this guide: https://flowxo.com/how-to-create-a-bot-for-telegram-short-and-simple-guide-for-beginners
- Invite your bot to a newly created group chat on Telegram.
- Obtain the CHAT_ID by issuing this command with credential strings replaced by your Telegram Bot credentials:
```curl -s "https://api.telegram.org/bot${STN_TELEGRAM_BOT_ID}:${STN_TELEGRAM_BOT_APIKEY}/getUpdates" | grep -o -E '"chat":{"id":[-0-9]*,' | head -n 1```

- Make sure, you vsftpd/proftpd installation receives the mp4 video files from the YI camera correctly at the configured "FOLDER_TO_WATCH" location. You may want to wave your hand in front of the camera and copy the mp4 footage which soon got uploaded to the FTP folder to another folder on your debian box to have some test file at hand you can copy back into the "incoming FTP folder" later for testing of your parameters and setup.

- Make a test run of the script to see if everything is configured correctly.
```
bash "/etc/systemd/system/camwatcher.service.d/camwatcher.sh" cron camera01
```

- If you get a notification for your "waving hand in front of the camera", you've configured it the right way. You can now enable the systemd service to have it run in the background and run on boot.
```
systemctl enable camwatcher@camera01
systemctl start camwatcher@camera01
systemctl status camwatcher@camera01
journalctl -f -u camwatcher@camera01
# To uninstall
# systemctl disable camwatcher@camera01
# systemctl stop camwatcher@camera01
```

Feedback appreciated. I'm running this script successfully on my two yi cameras and the debian box since over a year, and together with the yi-hack it made this camera a perfect outdoor surveillance solution with less false alarms.

