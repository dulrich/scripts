#!/bin/sh

user=$(echo "$1" | sed s/\'//)
pass=$(echo "$2" | sed s/\'/\'\'/)

echo "
CREATE USER '$user'@'localhost' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON $user.* TO '$user'@'localhost'
	WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON $user.* TO '$user'@'%'
	WITH GRANT OPTION;
"
