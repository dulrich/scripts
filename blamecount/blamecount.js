// blamecount: count lines by each contributor
// Copyright 2016  David Ulrich
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

var _   = require("lodash");
var A   = require("async");
var fs  = require("fs");
var git = require("nodegit");
var P   = require("path");

var log = console.log;

var config = require("./config.json");

var stop = {
	dirs : config.stopdirs || [],
	files: /.+\.min\.(js|css)$/i,
};

var user_lines = {
	c    : 0,
	cc   : 0,
	cpp  : 0,
	cs   : 0,
	css  : 0,
	h    : 0,
	htm  : 0,
	html : 0,
	js   : 0,
	less : 0,
	lua  : 0,
	php  : 0,
	pl   : 0,
	py   : 0,
	rb   : 0,
	sh   : 0,
	sql  : 0
};

var lines = {};

function add_lines(user,lang,count) {
	lines[user] = lines[user] || _.cloneDeep(user_lines);
	
	if (typeof lines[user][lang] == "undefined") return;
	
	lines[user][lang] += count;
}

function count_file(repo,file,cb) {
	if (git.Ignore.pathIsIgnored(repo,file)) {
		return cb(null);
	}
	
	if (file.match(stop.files)) {
		log("skipped",file);
		return cb(null);
	}
	
	git.Blame.file(repo,file)
		.then(function(blame) {
			var hunk,hunks,i;
			
			hunks = blame.getHunkCount();
			
			for(i = 0;i < hunks;i++) {
				hunk = blame.getHunkByIndex(i);
				
				add_lines(
					hunk.origSignature().name(),
					file.split(".").slice(-1),
					hunk.linesInHunk()
				);
				// lines[hunk.origSignature().name()] = lines[hunk.origSignature().name()] || 0;
				// lines[hunk.origSignature().name()] += hunk.linesInHunk();
			}
			
			cb(null);
		})
		.catch(function(err) {
			log("blame err",file,err);
			cb(null);
		});
}

function count_dir(repo,base,dir,cb) {
	if (git.Ignore.pathIsIgnored(repo,dir)) {
		log("ignored",dir);
		return cb(null);
	}
	
	if (stop.dirs.indexOf(dir) > -1) {
		log("skipped",dir);
		return cb(null);
	}
	
	fs.readdir(P.join(base,dir),function(err,res) {
		if (err) {
			log("dir error",dir,err);
			return cb(null);
		}
		
		A.parallel(_.map(res,function(path) {
			return function(acb) {
				fs.lstat(P.join(base,dir,path),function(serr,stats) {
					if (serr) return acb(serr);
					
					if (stats.isDirectory() && !stats.isSymbolicLink()) {
						return count_dir(repo,base,P.join(dir,path),acb);
					}
					
					if (!stats.isFile() || stats.isSymbolicLink()) {
						return acb(null);
					}
					
					count_file(repo,P.join(dir,path),acb);
				});
			};
		}),function(err,res) {
			if (err) log("async error",err);
			
			log("finished dir",dir);
			
			cb(null);
		});
	});
}

git.Repository.open(config.basepath)
	.then(function(repo) {
		log("got repo");
		
		count_dir(repo,config.basepath,"",function(err) {
			if (err) return log("count error",err);
			
			log(lines);
			
			log("done");
		});
	})
	.catch(function(err) {
		log("open error",err);
	});
