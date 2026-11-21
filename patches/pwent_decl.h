#ifndef DB_PWENT_DECL_H
#define DB_PWENT_DECL_H
#include <config.h>
#include <pwd.h>
struct passwd *getpwent(void);
void setpwent(void);
void endpwent(void);
#endif
