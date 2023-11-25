bench:
	~/bin/benchmarker --stage=prod --request-timeout=10s --initialize-request-timeout=60s

nginx.rotate:
	sudo mv /var/log/nginx/access.log /var/log/nginx/access.log.old
	sudo systemctl reload nginx

nginx.log:
	sudo tail -f /var/log/nginx/access.log

nginx.alp:
	alp json \
		--sort sum -r \
		-m "/user/\w+/present/receive,/user/\w+/gacha/draw/\w+/\w+,/user/\w+/present/index/\w+,/user/\w+/card/addexp/\w+,/user/\w+/gacha/index,/user/\w+/item,/user/\w+/home,/admin/user/\w+,/user/\w+/reward,/user/\w+/card" \
		-o count,method,uri,min,avg,max,sum \
		< /var/log/nginx/access.log

mysql-slow.rotate:
	sudo mv /var/log/mysql/mysql-slow.log /var/log/mysql/mysql-slow.log.old && sudo mysqladmin flush-logs

mysql-slow.log:
	sudo tail -f /var/log/mysql/mysql-slow.log

mysql-slow.dump:
	sudo mysqldumpslow /var/log/mysql/mysql-slow.log

mysql-slow.digest:
	sudo pt-query-digest /var/log/mysql/mysql-slow.log

service.restart:
	sudo systemctl restart isupipe-ruby.service

service.log:
	sudo journalctl -u isupipe-ruby.service

mysql.isupipe:
	sudo mysql -uroot  -proot -D isupipe

mysql.isudns:
	sudo mysql -uroot  -proot -D isudns

