extern int havesecstore(char *addr, char *owner);
extern char *secstore;
extern char secstorebuf[65536];
extern char *secstorefetch(char *addr, char *owner, char *passwd);
extern char *authaddr;
extern char *readcons(char *prompt, char *def, int secret);
extern int exportfs(int, int);
extern char *user;
extern char *getkey(char*, char*);
extern char *findkey(char**, char*);
extern int dialfactotum(void);
extern char *getuser(void);
