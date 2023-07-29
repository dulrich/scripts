
/* ----- cprocs.c ----- */

struct child_process_info {
	int pid;
	char state; // 'q'ueued, 'r'unning, 'd'ead
	int exit_status;
	int pty;
	int child_stdin;
	int child_stdout;
	int child_stderr;
	FILE* f_stdin;
	FILE* f_stdout;
	FILE* f_stderr;
	
	char* output_buffer;
	size_t buf_alloc;
	size_t buf_len;
};


struct job {
	int type; // c = child process, f = function
	volatile int state;
	
	union {
		int (*fn)(void*);
		char* cmd;
	};
	union {
		struct child_process_info* cpi;
		void* user_data;
	};
};


struct child_process_info* exec_cmdline_pipe(char* cmdline);
struct child_process_info* exec_process_pipe(char* exec_path, char* args[]);



void free_cpi(struct child_process_info* cpi) {
	if(cpi->output_buffer) free(cpi->output_buffer);
	
	if(cpi->f_stdin) fclose(cpi->f_stdin);
	if(cpi->f_stdout) fclose(cpi->f_stdout);
	if(cpi->f_stderr) fclose(cpi->f_stderr);
	
	if(cpi->child_stdin) close(cpi->child_stdin);
	if(cpi->child_stdout) close(cpi->child_stdout);
	if(cpi->child_stderr) close(cpi->child_stderr);
	
	if(cpi->pty) close(cpi->pty);
	
	free(cpi);
}


void read_cpi(struct child_process_info* cpi) {

	while(1) {
		if(cpi->buf_len > cpi->buf_alloc - 128) {
			cpi->buf_alloc *= 2;
			cpi->output_buffer = realloc(cpi->output_buffer, cpi->buf_alloc * sizeof(*cpi->output_buffer));
		}
		
		int ret = read(cpi->pty, cpi->output_buffer + cpi->buf_len, cpi->buf_alloc - cpi->buf_len - 1);
		if(ret > 0) cpi->buf_len += ret;
		else return;
	}
	
	return ;
}

char* printpct(float f) {
	static char buf[32];
	if(f != 100) sprintf(buf, "\e[1;33m %2.0f%%\e[0m", f); 
	else sprintf(buf, "\e[1;32m100%%\e[0m");
	
	return buf;
}


int execute_mt(strlist* cmds, int threads, char* fmt, struct child_process_info*** cpis) {
	int ret = 0;
	int running = 0;
	
	struct child_process_info** procs = calloc(1, cmds->len * sizeof(*procs));
	if(cpis) *cpis = procs;
	
	if(fmt) printf(fmt, printpct(0)), fflush(stdout);
	
	int waiting = cmds->len;
	while(waiting > 0) {
		for(int i = 0; i < cmds->len; i++) {	
			
			// keep the cores full
			if(!procs[i] && running < threads) {
				procs[i] = exec_cmdline_pipe(cmds->entries[i]);
				procs[i]->state = 'r';
				running++;
			}
			
			if(!procs[i] || procs[i]->state == 'd') continue;
			
			
			read_cpi(procs[i]);	
			
			int status;
			// returns 0 if nothing happened, -1 on error, childpid if it exited
			int pid = waitpid(procs[i]->pid, &status, WNOHANG);
			if(pid != 0) {
				procs[i]->state = 'd';
				waiting--;
				running--;
				
				if(fmt) printf("\r"), printf(fmt, printpct((cmds->len - waiting) * 100.0f / (float)cmds->len)), fflush(stdout);
				
				read_cpi(procs[i]);
				
				procs[i]->output_buffer[procs[i]->buf_len] = 0;
				procs[i]->exit_status = WEXITSTATUS(status);
				
				if(!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
//					printf("error on pid %d/%d = %d\n", pid, procs[i]->pid, WEXITSTATUS(status));	
//					printf("%s\n", procs[i]->output_buffer);
					ret = 1;
				}
			}
			
			
		}
		
		
		usleep(100);
	}
	
	if(fmt) {
		printf("\r");
		if(ret) printf(fmt, "\e[1;31mFAIL\e[0m");
		else printf(fmt, "\e[32mDONE\e[0m");
		fflush(stdout);
	}
	
	printf("\n");
	
	
	return ret;
}



struct child_process_info* exec_cmdline_pipe(char* cmdline) {
	// kinda janky. it doesn't handle quotes
	char** args = strsplit(" ", cmdline);

	struct child_process_info* cpi = exec_process_pipe(args[0], args);
//	printf("executing '%s'\n", cmdline);
//	for(char** s = args; *s; s++) printf("%d - '%s'\n", (s-args), *s);
	free_strpp(args);
	
	return cpi;
}


// effectively a better, asynchronous version of system()
// redirects and captures the child process i/o
struct child_process_info* exec_process_pipe(char* exec_path, char* args[]) {
	
	
	int master, slave; // pty
	
	
	errno = 0;
	if(openpty(&master, &slave, NULL, NULL, NULL) < 0) {
		fprintf(stderr, "Error opening new pty for '%s' [errno=%d]\n", exec_path, errno);
		return NULL;
	}
	
	errno = 0;
	
	int childPID = fork();
	if(childPID == -1) {
		
		fprintf(stderr, "failed to fork trying to execute '%s'\n", exec_path);
		perror(strerror(errno));
		return NULL;
	}
	else if(childPID == 0) { // child process
		
		setsid();
		
		// redirect standard fd's to the pipe fd's 
		if(dup2(slave, fileno(stdin)) == -1) {
			printf("failed 1\n");
			exit(errno);
		}
		if(dup2(slave, fileno(stdout)) == -1) {
			printf("failed 2\n");
			exit(errno);
		}
		if(dup2(slave, fileno(stderr)) == -1) {
			printf("failed 3\n");
			exit(errno);
		}
		
		if(ioctl(slave, TIOCSCTTY, NULL) < 0) {
			fprintf(stderr, "ioctl TIOCSCTTY failed: %s, %d\n", exec_path, errno);
		}
		
		// close original fd's
		close(master);
		close(slave);
		
		// die when the parent does (linux only)
		prctl(PR_SET_PDEATHSIG, SIGHUP);
		
		// swap for the desired program
		execvp(exec_path, args); // never returns if successful
		 
		fprintf(stderr, "failed to execute '%s'\n", exec_path);
		exit(1); // kill the forked process 
	}
	else { // parent process
		
		// close the child-end of the pipes
		struct child_process_info* cpi;
		cpi = calloc(1, sizeof(*cpi));
		cpi->pid = childPID;
		cpi->pty = master;
		
		cpi->state = 'q';
		cpi->buf_alloc = 4096;
		cpi->output_buffer = malloc(cpi->buf_alloc * sizeof(*cpi->output_buffer));
		
		// set to non-blocking
		fcntl(master, F_SETFL, fcntl(master, F_GETFL) | FNDELAY | O_NONBLOCK);
		
		close(slave);
		
// 		tcsetattr(STDIN_FILENO, TCSANOW, &master);
// 		fcntl(master, F_SETFL, FNDELAY);
		
// 		int status;
		// returns 0 if nothing happened, -1 on error
// 		pid = waitpid(childPID, &status, WNOHANG);
		
		return cpi;
	}
	
	return NULL; // shouldn't reach here
}


/* -END- cprocs.c ----- */


