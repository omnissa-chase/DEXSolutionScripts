<h1>Interactive Reboot Script With User Deferral 1.2.0.7.</h1>

A script for admins managing registered mode devices.

Designed to let users snooze, postpone, or pick a time — great for organizations that want to enforce reboots without being heavy‑handed. 

There are a few provisions admins should know before using this script -  
* This script uses toast notifications
* This script does not use any 3rd party libraries and instead relies on naitive .NET libaries
* The script has code blocks inside of it  
* The script saves scripts locally to allow the Task Scheduler to execute them.  This is critical since it provides a way to execute these script asyncronously and to allow this script to run as the current user (required in order for toast notifications to work)
* The script creates dynamic scheduled tasks