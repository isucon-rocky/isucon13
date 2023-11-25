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

service.status:
	sudo systemctl status isupipe-ruby.service

service.restart:
	sudo systemctl restart isupipe-ruby.service

service.log:
	sudo journalctl -u isupipe-ruby.service

mysql.sh:
	sudo mysql -uisucon -pisucon -D isucon

deploy1:
	scp -r ./webapp/ruby isucon1:~/webapp
	scp -r ./etc/mysql/mysql.conf.d/mysqld.cnf isucon1:/etc/mysql/mysql.conf.d
	scp -r ./etc/nginx/isupipe.conf isucon1:/etc/nginx/sites-enabled
	scp -r ./etc/nginx/nginx.conf isucon1:/etc/nginx
	scp -r ./Makefile isucon1:~/Makefile
	ssh isucon1 "sudo systemctl restart mysql"
	ssh isucon1 "sudo systemctl restart nginx.service"
	ssh isucon1 "sudo systemctl daemon-reload"
	ssh isucon1 "sudo systemctl restart isupipe-ruby.service"

deploy2:
	scp -r ./webapp/ruby isucon2:~/webapp
	scp -r ./etc/mysql/mysql.conf.d/mysqld.cnf isucon2:/etc/mysql/mysql.conf.d
	scp -r ./etc/nginx/isupipe.conf isucon2:/etc/nginx/sites-enabled
	scp -r ./etc/nginx/nginx.conf isucon2:/etc/nginx
	scp -r ./Makefile isucon2:~/Makefile
	ssh isucon2 "sudo systemctl restart mysql"
	ssh isucon2 "sudo systemctl restart nginx.service"
	ssh isucon2 "sudo systemctl daemon-reload"
	ssh isucon2 "sudo systemctl restart isupipe-ruby.service"

deploy3:
	scp -r ./webapp/ruby isucon3:~/webapp
	scp -r ./etc/mysql/mysql.conf.d/mysqld.cnf isucon3:/etc/mysql/mysql.conf.d
	scp -r ./etc/nginx/isupipe.conf isucon3:/etc/nginx/sites-enabled
	scp -r ./etc/nginx/nginx.conf isucon3:/etc/nginx
	scp -r ./Makefile isucon3:~/Makefile
	ssh isucon3 "sudo systemctl restart mysql"
	ssh isucon3 "sudo systemctl restart nginx.service"
	ssh isucon3 "sudo systemctl daemon-reload"
	ssh isucon3 "sudo systemctl restart isupipe-ruby.service"
