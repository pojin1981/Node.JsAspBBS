<%
function ss(ns) {
	if(!ns) ns = "global.";
	var root = InitSession(site).data;
	root[ns + "root"] ??= { sessId: root.sessId };
	return root;
}

function cc(k, f, t) {
	cache.redis ??= new Object;
	var root = cache.redis[site.host.domain] ??= new Object;
	if(!k) return root;
	var rs = root[k];
	var timer = t * 1000;
	if(rs) {
		if(rs.time - site.sys.sTime + timer > 0) return rs.value;
		// 数据过期了，重新获取
		clearTimeout(rs.handler);
	}
	try { var value = f(); }
	catch(err) { throw err; }
	if(value instanceof Promise) value.then(v => {
		root[k] = { value: v, time: site.sys.sTime };
	});
	// 没有初始化
	root[k] = { value, time: site.sys.sTime };
	root[k].handler = setTimeout(() => {
		// 定时清理缓存
		if(!root[k]) return;
		delete root[k];
	}, timer);
	return root[k].value;
}

function html(str) { return (str + "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
function tojson(obj) { return JSON.stringify(obj); }
function fromjson(str) { return JSON.parse(str); }
function redir(url) { IIS.redir(site, url); }
function mappath(path) { return site.getPath(path); }

function md5(str = "a", len = 32) {
	const crypto = cache.CryptoModule ??= require('crypto');
	const hash = crypto.createHash('md5'); hash.update(str);
	return hash.digest('hex').substr((32 - len) / 2, len || 32);
}

function ensureDir(dir) {
	dir = site.getPath(dir).replace(/\\/g, "/").replace(/\/$/, "");
	var recurse = dir => {
		if(fs.existsSync(dir)) return dir;
		recurse(dir.substr(0, dir.lastIndexOf("/")));
		fs.mkdirSync(dir, 0777);
		return dir;
	};
	return recurse(dir);
}

function db(dbPath) {
	dbPath ??= sys.dbPath || "/App_Data/sqlite.db";
	sys.db ??= new Object;
	if(sys.db[dbPath]) return sys.db[dbPath];
	return sys.db[dbPath] = new SQLiteHelper(dbPath);
}

function closeAllDb() {
	if(!sys.db) return;
	for(var db in sys.db) {
		sys.db[db].close();
		delete sys.db[db];
	}
}

// SQLite DbHelper
function SQLiteHelper(dbPath) {
	try { var SQLite = cache.SQLiteModule ??= require("sqlite3").verbose(); }
	catch(e) { throw new Error("您可能需要运行一次：npm install sqlite3"); }
	dbPath = site.getPath(dbPath);
	var dbo = new SQLite.Database(dbPath);
	var parseArg = args => {
		if(!args || args instanceof Array) return args;
		var par = new Object;
		for(var x in args) par["@" + x] = args[x];
		return par;
	};
	this.query = function(sql, args) {
		this.lastSql = { sql: sql, par: args };
		return new Promise((resolve, reject) => {
			dbo.all(sql, parseArg(args), (err, rows) => {
				if (err) reject(err);
				else resolve(rows);
			});
		});
	};
	
	this.fetch = function(sql, args) {
		this.lastSql = { sql: sql, par: args };
		return new Promise((resolve, reject) => {
			dbo.get(sql, parseArg(args), (err, row) => {
				if (err) reject(err);
				else resolve(row);
			});
		});
	};

	this.scalar = function(sql, args) {
		this.lastSql = { sql: sql, par: args };
		return new Promise((resolve, reject) => {
			dbo.get(sql, parseArg(args), (err, row) => {
				row ??= new Object;
				if (err) reject(err);
				else resolve(row[Object.keys(row)[0]]);
			});
		});
	};

	this.none = function(sql, args) {
		this.lastSql = { sql: sql, par: args };
		// 执行 SQL 并返回受影响行数
		return new Promise((resolve, reject) => {
			dbo.run(sql, parseArg(args), function(err) {
				if (err) return reject(err);
				return resolve(this.changes);
			});
		});
	};

	this.table = function(tablename) {
		var ins = new Object; this.pager = new Object;
		var tables = [ tablename ], where = orderby = limit = groupby = "", select = "*";

		ins.join = (tbl, dir = "left") => { tables.push(dir + " join " + tbl); return ins; };

		ins.where = cond => { where = " where " + cond; return ins; };

		ins.order = ins.orderby = col => { orderby = " order by " + col; return ins; };

		ins.limit = (start, count) => { limit = " limit " + start + ", " + count; return ins; };

		ins.group = ins.groupby = col => { groupby = " group by " + col; return ins; };

		ins.select = cols => { select = cols; return ins; };

		ins.toString = () => {
			var sql = "select " + select + " from " + tables.join(" ") + where + groupby + orderby + limit;
			return sql;
		};

		ins.astable = n => {
			tables = [ "(" + ins + ") as " + n ];
			where = orderby = limit = groupby = "", select = "*";
			return ins;
		};

		ins.page = async (sort, size, page, args) => {
			page ??= 1; if(page < 1) page = 1;
			var sql = ins.toString();
			var total = await this.scalar("select count(*) as value from (" + sql + ") as t", args);
			var pages = Math.ceil(total / size);
			var start = (page - 1) * size;
			this.pager = {
				rownum: total,
				pagenum: pages,
				pagesize: size,
				curpage: page,
				args: args
			};
			orderby = " order by " + sort;
			limit = " limit " + start + ", " + size;
			return ins;
		};

		ins.query = args => this.query(ins.toString(), args || this.pager?.args);
		ins.fetch = args => this.fetch(ins.toString(), args || this.pager?.args);
		ins.scalar = args => this.scalar(ins.toString(), args || this.pager?.args);

		return ins;
	}

	this.insert = async function(tablename, rows) {
		if(!(rows instanceof Array)) rows = [ rows ];
		if(!rows[0]) return;
		var sql = "insert into `" + tablename + "` (";
		var keys = new Array, vals = new Array;
		for(var k in rows[0]) {
			keys.push("`" + k + "`");
			vals.push("@" + k);
		}
		sql += keys.join(",") + ") values (" + vals.join(",") + ")";
		this.lastSql = { sql: sql };
		var stmt = dbo.prepare(sql);
		// 开启事务
		await this.none("begin transaction");
		await rows.forEach(async row => {
			var par = this.lastSql.par = new Object;
			for(var k in row) par["@" + k] = row[k];
			await stmt.run(par);
		});
		await stmt.finalize();
		// 提交事务
		await this.none("commit");
	}

	this.update = function(tablename, row, parWhere) {
		if(!parWhere) return 0;
		var sql = "update `" + tablename + "` set ";
		var keys = new Array, vals = new Object;
		for(var k in row) {
			keys.push("`" + k + "`=@" + k);
			vals[k] = row[k];
		}
		sql += keys.join(",");
		var arrWhere = new Array;
		for(var k in parWhere) {
			arrWhere.push("`" + k + "`=@" + k);
			vals[k] = parWhere[k];
		}
		sql += " where " + arrWhere.join(" and ");
		this.lastSql = { sql, par: vals };
		return this.none(sql, vals);
	}

	this.create = function(tablename, cols) {
		var sql = "create table `" + tablename + "`(";
		cols.forEach((x, i) => {
			if("string" == typeof x) x = [ x ];
			let col = x[0];
			if(x[1] !== x.none) col += " not null default(" + x[1] + ")";
			if(x[2]) col += " not null primary key autoincrement";
			cols[i] = col;
		});
		sql += cols.join(", ") + ")";
		return this.none(sql);
	}

	this.close = () => {
		dbo.close();
		delete sys.db[dbPath];
	};
}
%>