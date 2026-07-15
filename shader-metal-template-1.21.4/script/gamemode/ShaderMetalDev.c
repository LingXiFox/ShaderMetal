#include <jni.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct JLI_List_ {
    char **elements;
    size_t size;
    size_t capacity;
};

typedef struct JLI_List_ *JLI_List;

extern void JLI_InitArgProcessing(jboolean hasJavaArgs,
                                  jboolean disableArgFile);
extern JLI_List JLI_PreprocessArg(const char *arg,
                                 jboolean expandSourceOpt);
extern jboolean JLI_AddArgsFromEnvVar(JLI_List args,
                                     const char *variableName);
extern JLI_List JLI_List_new(size_t capacity);
extern void JLI_List_add(JLI_List list, char *element);
extern char *JLI_StringDup(const char *value);
extern void JLI_MemFree(void *pointer);
extern int JLI_Launch(int argc, char **argv,
                      int jargc, const char **jargv,
                      int appclassc, const char **appclassv,
                      const char *fullversion, const char *dotversion,
                      const char *pname, const char *lname,
                      jboolean javaargs, jboolean cpwildcard,
                      jboolean javaw, jint ergoClass);

#ifndef SHADERMETAL_JAVA_VERSION
#define SHADERMETAL_JAVA_VERSION "21"
#endif

static const char *gPidFile = NULL;

static void removePidFile(void) {
    if (gPidFile != NULL) {
        unlink(gPidFile);
    }
}

static int writePidFile(const char *path) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (descriptor < 0) {
        return -1;
    }
    char buffer[64];
    int length = snprintf(buffer, sizeof(buffer), "%ld\n", (long)getpid());
    ssize_t written = write(descriptor, buffer, (size_t)length);
    int closeResult = close(descriptor);
    return written == length && closeResult == 0 ? 0 : -1;
}

int main(int argc, char **argv) {
    const char *runDirectory = getenv("SHADERMETAL_RUN_DIR");
    const char *pidFile = getenv("SHADERMETAL_PID_FILE");
    if (runDirectory == NULL || runDirectory[0] == '\0' ||
        chdir(runDirectory) != 0) {
        fprintf(stderr, "ShaderMetal Game Mode launcher cannot enter %s: %s\n",
                runDirectory == NULL ? "<unset>" : runDirectory,
                strerror(errno));
        return 72;
    }
    if (pidFile == NULL || pidFile[0] == '\0' || writePidFile(pidFile) != 0) {
        fprintf(stderr, "ShaderMetal Game Mode launcher cannot write its PID: %s\n",
                strerror(errno));
        return 73;
    }
    gPidFile = pidFile;
    atexit(removePidFile);

    JLI_InitArgProcessing(JNI_FALSE, JNI_FALSE);
    JLI_List arguments = JLI_List_new((size_t)argc + 8U);
    JLI_List_add(arguments, JLI_StringDup(argv[0]));
    JLI_AddArgsFromEnvVar(arguments, "JDK_JAVA_OPTIONS");

    for (int index = 1; index < argc; ++index) {
        JLI_List expanded = JLI_PreprocessArg(argv[index], JNI_TRUE);
        if (expanded == NULL) {
            JLI_List_add(arguments, JLI_StringDup(argv[index]));
            continue;
        }
        for (size_t item = 0; item < expanded->size; ++item) {
            JLI_List_add(arguments, expanded->elements[item]);
        }
        JLI_MemFree(expanded->elements);
        JLI_MemFree(expanded);
    }

    int expandedArgc = (int)arguments->size;
    JLI_List_add(arguments, NULL);
    return JLI_Launch(
        expandedArgc, arguments->elements,
        0, NULL, 0, NULL,
        SHADERMETAL_JAVA_VERSION, SHADERMETAL_JAVA_VERSION,
        "java", "java", JNI_FALSE, JNI_TRUE, JNI_FALSE, 0);
}
