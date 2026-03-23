#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define PTY_DEBUG 1

#ifdef PTY_DEBUG
static int print_debug;
#endif

#ifdef PerlIO
typedef int SysRet;
typedef PerlIO * InOutStream;
#else
# define PERLIO_IS_STDIO 1
# define PerlIO_fileno fileno
typedef int SysRet;
typedef FILE * InOutStream;
#endif

#include "patchlevel.h"

/*
 * The following pty-allocation code was heavily inspired by its
 * counterparts in openssh 3.0p1 and Xemacs 21.4.5 but is a complete
 * rewrite by me, Roland Giersig <RGiersig@cpan.org>.
 *
 * Nevertheless my references to Tatu Ylonen <ylo@cs.hut.fi>
 * and the Xemacs development team for their inspiring code.
 *
 * mysignal and strlcpy were borrowed from openssh and have their
 * copyright messages attached.
 *
 * Windows ConPTY support added 2026.
 */

#ifdef HAVE_CONPTY
/*
 * ===== Windows ConPTY implementation =====
 *
 * On Windows, we use the ConPTY (Pseudo Console) API available since
 * Windows 10 version 1809.  ConPTY provides two unidirectional pipes
 * (input and output) rather than a single bidirectional fd.  To maintain
 * API compatibility with the POSIX pty interface (where the master fd
 * supports both read and write), we create a loopback socket pair and
 * spawn bridge threads that copy data between the socket and the ConPTY
 * pipes.  The socket fd is returned as the "master" fd.
 */

#include <winsock2.h>
#include <ws2tcpip.h>
#include <io.h>
#include <process.h>

/*
 * Fallback declarations for ConPTY API.
 *
 * perl.h already includes <windows.h> on Win32, so we cannot
 * retroactively raise _WIN32_WINNT.  Instead, provide our own
 * declarations when the headers did not expose them — this is
 * the case on older MinGW-w64 toolchains shipped with some
 * Strawberry Perl versions.
 *
 * The functions themselves live in kernel32.dll and are linked
 * via -lkernel32 (added in Makefile.PL).
 */
#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE \
    ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)
typedef VOID* HPCON;
WINBASEAPI HRESULT WINAPI CreatePseudoConsole(COORD, HANDLE, HANDLE, DWORD, HPCON*);
WINBASEAPI HRESULT WINAPI ResizePseudoConsole(HPCON, COORD);
WINBASEAPI VOID    WINAPI ClosePseudoConsole(HPCON);
#endif

/* ConPTY slot table: maps master fd -> ConPTY resources */
#define MAX_CONPTY_SLOTS 64

typedef struct {
    int in_use;
    int master_fd;           /* the socket fd returned to Perl */
    HPCON hPC;               /* pseudo console handle */
    HANDLE hPipeIn_W;        /* write end: parent writes input to console */
    HANDLE hPipeOut_R;       /* read end: parent reads output from console */
    HANDLE hBridgeRead;      /* bridge thread: ConPTY output -> socket */
    HANDLE hBridgeWrite;     /* bridge thread: socket -> ConPTY input */
    SOCKET sock_internal;    /* internal socket end (connected to bridge threads) */
    SOCKET sock_master;      /* master socket end (converted to fd for Perl) */
} conpty_slot_t;

static conpty_slot_t conpty_slots[MAX_CONPTY_SLOTS];
static int conpty_initialized = 0;

static void
conpty_init(void)
{
    if (!conpty_initialized) {
        WSADATA wsaData;
        WSAStartup(MAKEWORD(2, 2), &wsaData);
        memset(conpty_slots, 0, sizeof(conpty_slots));
        conpty_initialized = 1;
    }
}

static conpty_slot_t *
conpty_find_slot(int master_fd)
{
    int i;
    for (i = 0; i < MAX_CONPTY_SLOTS; i++) {
        if (conpty_slots[i].in_use && conpty_slots[i].master_fd == master_fd)
            return &conpty_slots[i];
    }
    return NULL;
}

static conpty_slot_t *
conpty_alloc_slot(void)
{
    int i;
    for (i = 0; i < MAX_CONPTY_SLOTS; i++) {
        if (!conpty_slots[i].in_use) {
            memset(&conpty_slots[i], 0, sizeof(conpty_slot_t));
            conpty_slots[i].in_use = 1;
            return &conpty_slots[i];
        }
    }
    return NULL;
}

/*
 * Create a TCP loopback socket pair (Windows lacks socketpair()).
 * Returns 0 on success, -1 on failure.
 */
static int
win_socketpair(SOCKET pair[2])
{
    SOCKET listener;
    struct sockaddr_in addr;
    int addrlen = sizeof(addr);

    pair[0] = pair[1] = INVALID_SOCKET;

    listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET)
        return -1;

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;

    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) == SOCKET_ERROR)
        goto fail;
    if (getsockname(listener, (struct sockaddr *)&addr, &addrlen) == SOCKET_ERROR)
        goto fail;
    if (listen(listener, 1) == SOCKET_ERROR)
        goto fail;

    pair[0] = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (pair[0] == INVALID_SOCKET)
        goto fail;
    if (connect(pair[0], (struct sockaddr *)&addr, sizeof(addr)) == SOCKET_ERROR)
        goto fail;

    pair[1] = accept(listener, NULL, NULL);
    if (pair[1] == INVALID_SOCKET)
        goto fail;

    closesocket(listener);
    return 0;

fail:
    if (pair[0] != INVALID_SOCKET) closesocket(pair[0]);
    if (pair[1] != INVALID_SOCKET) closesocket(pair[1]);
    closesocket(listener);
    pair[0] = pair[1] = INVALID_SOCKET;
    return -1;
}

/*
 * Bridge thread: reads from ConPTY output pipe, writes to socket.
 * This runs until the pipe is closed or an error occurs.
 */
static unsigned __stdcall
bridge_read_thread(void *arg)
{
    conpty_slot_t *slot = (conpty_slot_t *)arg;
    char buf[4096];
    DWORD bytesRead;

    while (ReadFile(slot->hPipeOut_R, buf, sizeof(buf), &bytesRead, NULL)
           && bytesRead > 0) {
        int sent = 0;
        while (sent < (int)bytesRead) {
            int ret = send(slot->sock_internal, buf + sent,
                          (int)(bytesRead - sent), 0);
            if (ret <= 0) goto done;
            sent += ret;
        }
    }
done:
    return 0;
}

/*
 * Bridge thread: reads from socket, writes to ConPTY input pipe.
 * This runs until the socket is closed or an error occurs.
 */
static unsigned __stdcall
bridge_write_thread(void *arg)
{
    conpty_slot_t *slot = (conpty_slot_t *)arg;
    char buf[4096];

    while (1) {
        int ret = recv(slot->sock_internal, buf, sizeof(buf), 0);
        if (ret <= 0) break;
        DWORD bytesWritten;
        DWORD toWrite = (DWORD)ret;
        DWORD written = 0;
        while (written < toWrite) {
            if (!WriteFile(slot->hPipeIn_W, buf + written,
                          toWrite - written, &bytesWritten, NULL))
                goto done;
            written += bytesWritten;
        }
    }
done:
    return 0;
}

/*
 * Windows ConPTY-based pty allocation.
 *
 * Creates a pseudo console with bridge threads to provide a single
 * bidirectional socket fd as the "master".  The "slave" fd is set to -1
 * since on Windows the slave side is internal to ConPTY and gets
 * attached to child processes via spawn().
 */
static int
allocate_pty(int *ptyfd, int *ttyfd, char *namebuf, int namebuflen)
{
    HRESULT hr;
    HPCON hPC = NULL;
    HANDLE hPipeIn_R = INVALID_HANDLE_VALUE;
    HANDLE hPipeIn_W = INVALID_HANDLE_VALUE;
    HANDLE hPipeOut_R = INVALID_HANDLE_VALUE;
    HANDLE hPipeOut_W = INVALID_HANDLE_VALUE;
    SOCKET pair[2] = { INVALID_SOCKET, INVALID_SOCKET };
    conpty_slot_t *slot;
    COORD size;
    static int conpty_counter = 0;

    *ptyfd = -1;
    *ttyfd = -1;
    namebuf[0] = 0;

    conpty_init();

#if PTY_DEBUG
    if (print_debug)
        fprintf(stderr, "trying Windows ConPTY (CreatePseudoConsole)...\n");
#endif

    /* Create pipes for ConPTY I/O */
    if (!CreatePipe(&hPipeIn_R, &hPipeIn_W, NULL, 0))
        goto fail;
    if (!CreatePipe(&hPipeOut_R, &hPipeOut_W, NULL, 0))
        goto fail;

    /* Create the pseudo console (default 80x24) */
    size.X = 80;
    size.Y = 24;
    hr = CreatePseudoConsole(size, hPipeIn_R, hPipeOut_W, 0, &hPC);
    if (FAILED(hr)) {
#if PTY_DEBUG
        if (print_debug)
            fprintf(stderr, "CreatePseudoConsole failed: HRESULT 0x%lx\n",
                    (unsigned long)hr);
#endif
        goto fail;
    }

    /* Close the pipe ends that ConPTY now owns internally */
    CloseHandle(hPipeIn_R);
    hPipeIn_R = INVALID_HANDLE_VALUE;
    CloseHandle(hPipeOut_W);
    hPipeOut_W = INVALID_HANDLE_VALUE;

    /* Create a socket pair for the bidirectional master fd */
    if (win_socketpair(pair) < 0) {
#if PTY_DEBUG
        if (print_debug)
            fprintf(stderr, "win_socketpair failed\n");
#endif
        goto fail;
    }

    /* Allocate a tracking slot */
    slot = conpty_alloc_slot();
    if (!slot) {
        warn("IO::Tty: too many ConPTY instances (max %d)", MAX_CONPTY_SLOTS);
        goto fail;
    }

    slot->hPC = hPC;
    slot->hPipeIn_W = hPipeIn_W;
    slot->hPipeOut_R = hPipeOut_R;
    slot->sock_internal = pair[0];
    slot->sock_master = pair[1];

    /* Start bridge threads */
    slot->hBridgeRead = (HANDLE)_beginthreadex(NULL, 0,
        bridge_read_thread, slot, 0, NULL);
    slot->hBridgeWrite = (HANDLE)_beginthreadex(NULL, 0,
        bridge_write_thread, slot, 0, NULL);

    if (!slot->hBridgeRead || !slot->hBridgeWrite) {
        slot->in_use = 0;
        goto fail;
    }

    /* Convert the master socket to a C file descriptor */
    *ptyfd = _open_osfhandle((intptr_t)pair[1], 0);
    if (*ptyfd < 0) {
        slot->in_use = 0;
        goto fail;
    }
    slot->master_fd = *ptyfd;

    /* On Windows, the slave is internal to ConPTY.  We return -1 for ttyfd
     * and the Perl layer (IO::Pty) handles this specially. */
    *ttyfd = -1;

    /* Generate a synthetic tty name */
    _snprintf(namebuf, namebuflen, "conpty%d", conpty_counter++);
    namebuf[namebuflen - 1] = 0;

#if PTY_DEBUG
    if (print_debug)
        fprintf(stderr, "ConPTY allocated: master_fd=%d name=%s\n",
                *ptyfd, namebuf);
#endif

    return 1;

fail:
    if (hPC) ClosePseudoConsole(hPC);
    if (hPipeIn_R != INVALID_HANDLE_VALUE) CloseHandle(hPipeIn_R);
    if (hPipeIn_W != INVALID_HANDLE_VALUE) CloseHandle(hPipeIn_W);
    if (hPipeOut_R != INVALID_HANDLE_VALUE) CloseHandle(hPipeOut_R);
    if (hPipeOut_W != INVALID_HANDLE_VALUE) CloseHandle(hPipeOut_W);
    if (pair[0] != INVALID_SOCKET) closesocket(pair[0]);
    if (pair[1] != INVALID_SOCKET) closesocket(pair[1]);
    return 0;
}

/*
 * Windows-compatible winsize structure (struct winsize doesn't exist
 * on Windows, but we need it for pack_winsize/unpack_winsize).
 */
struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};

/*
 * Resize a ConPTY pseudo console.
 * Returns 1 on success, 0 on failure.
 */
static int
conpty_resize(int master_fd, int rows, int cols)
{
    conpty_slot_t *slot = conpty_find_slot(master_fd);
    if (slot && slot->hPC) {
        COORD size;
        size.X = (SHORT)cols;
        size.Y = (SHORT)rows;
        return SUCCEEDED(ResizePseudoConsole(slot->hPC, size));
    }
    return 0;
}

/*
 * Clean up a ConPTY slot when the master fd is closed.
 */
static void
conpty_close(int master_fd)
{
    conpty_slot_t *slot = conpty_find_slot(master_fd);
    if (!slot) return;

    if (slot->hPC) {
        ClosePseudoConsole(slot->hPC);
        slot->hPC = NULL;
    }
    if (slot->hPipeIn_W != INVALID_HANDLE_VALUE) {
        CloseHandle(slot->hPipeIn_W);
        slot->hPipeIn_W = INVALID_HANDLE_VALUE;
    }
    if (slot->hPipeOut_R != INVALID_HANDLE_VALUE) {
        CloseHandle(slot->hPipeOut_R);
        slot->hPipeOut_R = INVALID_HANDLE_VALUE;
    }
    /* Closing the internal socket will cause bridge threads to exit */
    if (slot->sock_internal != INVALID_SOCKET) {
        closesocket(slot->sock_internal);
        slot->sock_internal = INVALID_SOCKET;
    }
    if (slot->hBridgeRead) {
        WaitForSingleObject(slot->hBridgeRead, 1000);
        CloseHandle(slot->hBridgeRead);
        slot->hBridgeRead = NULL;
    }
    if (slot->hBridgeWrite) {
        WaitForSingleObject(slot->hBridgeWrite, 1000);
        CloseHandle(slot->hBridgeWrite);
        slot->hBridgeWrite = NULL;
    }
    slot->in_use = 0;
}

/*
 * Spawn a child process attached to a ConPTY.
 * Returns the process ID on success, 0 on failure.
 */
static DWORD
conpty_spawn(int master_fd, const char *command)
{
    conpty_slot_t *slot = conpty_find_slot(master_fd);
    STARTUPINFOEXW si;
    PROCESS_INFORMATION pi;
    SIZE_T attrListSize = 0;
    BOOL success;
    wchar_t *wcmd = NULL;
    int wlen;

    if (!slot || !slot->hPC)
        return 0;

    memset(&si, 0, sizeof(si));
    si.StartupInfo.cb = sizeof(STARTUPINFOEXW);

    /* Allocate attribute list for ConPTY */
    InitializeProcThreadAttributeList(NULL, 1, 0, &attrListSize);
    si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
        GetProcessHeap(), 0, attrListSize);
    if (!si.lpAttributeList)
        return 0;

    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0,
                                           &attrListSize)) {
        HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
        return 0;
    }

    if (!UpdateProcThreadAttribute(si.lpAttributeList, 0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   slot->hPC, sizeof(HPCON), NULL, NULL)) {
        DeleteProcThreadAttributeList(si.lpAttributeList);
        HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
        return 0;
    }

    /* Convert command to wide string */
    wlen = MultiByteToWideChar(CP_UTF8, 0, command, -1, NULL, 0);
    wcmd = (wchar_t *)HeapAlloc(GetProcessHeap(), 0,
                                 wlen * sizeof(wchar_t));
    if (!wcmd) {
        DeleteProcThreadAttributeList(si.lpAttributeList);
        HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
        return 0;
    }
    MultiByteToWideChar(CP_UTF8, 0, command, -1, wcmd, wlen);

    memset(&pi, 0, sizeof(pi));
    success = CreateProcessW(NULL, wcmd, NULL, NULL, FALSE,
                             EXTENDED_STARTUPINFO_PRESENT, NULL, NULL,
                             &si.StartupInfo, &pi);

    DeleteProcThreadAttributeList(si.lpAttributeList);
    HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
    HeapFree(GetProcessHeap(), 0, wcmd);

    if (success) {
        DWORD pid = pi.dwProcessId;
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return pid;
    }

    return 0;
}

#else /* !HAVE_CONPTY -- POSIX implementation */

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>

#ifdef HAVE_LIBUTIL_H
# include <libutil.h>
#endif /* HAVE_UTIL_H */

#ifdef HAVE_UTIL_H
# ifdef UTIL_H_ABS_PATH
#  include UTIL_H_ABS_PATH
# elif ((PATCHLEVEL < 19) || ((PATCHLEVEL == 19) && (SUBVERSION < 4)))
#  include <util.h>
# endif
#endif /* HAVE_UTIL_H */

#ifdef HAVE_PTY_H
# include <pty.h>
#endif

#ifdef HAVE_SYS_PTY_H
# include <sys/pty.h>
#endif

#ifdef HAVE_SYS_PTYIO_H
# include <sys/ptyio.h>
#endif

#if defined(HAVE_DEV_PTMX) && defined(HAVE_SYS_STROPTS_H)
# include <sys/stropts.h>
#endif

#ifdef HAVE_TERMIOS_H
#include <termios.h>
#endif

#ifdef HAVE_TERMIO_H
#include <termio.h>
#endif

#ifndef O_NOCTTY
#define O_NOCTTY 0
#endif


/* from  $OpenBSD: misc.c,v 1.12 2001/06/26 17:27:24 markus Exp $        */

/*
 * Copyright (c) 2000 Markus Friedl.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <signal.h>

typedef void (*mysig_t)(int);

static mysig_t
mysignal(int sig, mysig_t act)
{
#ifdef HAVE_SIGACTION
        struct sigaction sa, osa;

        if (sigaction(sig, NULL, &osa) == -1)
                return (mysig_t) -1;
        if (osa.sa_handler != act) {
                memset(&sa, 0, sizeof(sa));
                sigemptyset(&sa.sa_mask);
                sa.sa_flags = 0;
#if defined(SA_INTERRUPT)
                if (sig == SIGALRM)
                        sa.sa_flags |= SA_INTERRUPT;
#endif
                sa.sa_handler = act;
                if (sigaction(sig, &sa, NULL) == -1)
                        return (mysig_t) -1;
        }
        return (osa.sa_handler);
#else
        return (signal(sig, act));
#endif
}

/*  from  $OpenBSD: strlcpy.c,v 1.5 2001/05/13 15:40:16 deraadt Exp $     */

/*
 * Copyright (c) 1998 Todd C. Miller <Todd.Miller@courtesan.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef HAVE_STRLCPY

/*
 * Copy src to string dst of size siz.  At most siz-1 characters
 * will be copied.  Always NUL terminates (unless siz == 0).
 * Returns strlen(src); if retval >= siz, truncation occurred.
 */
static size_t
strlcpy(char *dst, const char *src, size_t siz)
{
        register char *d = dst;
        register const char *s = src;
        register size_t n = siz;

        /* Copy as many bytes as will fit */
        if (n != 0 && --n != 0) {
                do {
                        if ((*d++ = *s++) == 0)
                                break;
                } while (--n != 0);
        }

        /* Not enough room in dst, add NUL and traverse rest of src */
        if (n == 0) {
                if (siz != 0)
                        *d = '\0';              /* NUL-terminate dst */
                while (*s++)
                        ;
        }

        return(s - src - 1);    /* count does not include NUL */
}

#endif /* !HAVE_STRLCPY */

/*
 * Move file descriptor so it doesn't collide with stdin/out/err
 */

static void
make_safe_fd(int * fd)
{
  if (*fd < 3) {
    int newfd;
    newfd = fcntl(*fd, F_DUPFD, 3);
    if (newfd < 0) {
      if (PL_dowarn)
	warn("IO::Tty::pty_allocate(nonfatal): tried to move fd %d up but fcntl() said %.100s", *fd, strerror(errno));
    } else {
      close (*fd);
      *fd = newfd;
    }
  }
}

/*
 * After having acquired a master pty, try to find out the slave name,
 * initialize and open the slave.
 */

#if defined (HAVE_PTSNAME)
char * ptsname(int);
#endif

static int
open_slave(int *ptyfd, int *ttyfd, char *namebuf, int namebuflen)
{
    /*
     * now do some things that are supposedly healthy for ptys,
     * i.e. changing the access mode.
     */
#if defined(HAVE_GRANTPT) ||  defined(HAVE_UNLOCKPT)
    {
	mysig_t old_signal;
	old_signal = mysignal(SIGCHLD, SIG_DFL);
#if defined(HAVE_GRANTPT)
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying grantpt()...\n");
#endif
	if (grantpt(*ptyfd) < 0) {
	    if (PL_dowarn)
		warn("IO::Tty::pty_allocate(nonfatal): grantpt(): %.100s", strerror(errno));
	}

#endif /* HAVE_GRANTPT */
#if defined(HAVE_UNLOCKPT)
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying unlockpt()...\n");
#endif
	if (unlockpt(*ptyfd) < 0) {
	    if (PL_dowarn)
		warn("IO::Tty::pty_allocate(nonfatal): unlockpt(): %.100s", strerror(errno));
	}
#endif /* HAVE_UNLOCKPT */
	mysignal(SIGCHLD, old_signal);
    }
#endif /* HAVE_GRANTPT || HAVE_UNLOCKPT */


    /*
     * find the slave name, if we don't have it already
     */

#if defined (HAVE_PTSNAME_R)
    if (namebuf[0] == 0) {
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying ptsname_r()...\n");
#endif
	if(ptsname_r(*ptyfd, namebuf, namebuflen)) {
	    if (PL_dowarn)
		warn("IO::Tty::open_slave(nonfatal): ptsname_r(): %.100s", strerror(errno));
	}
    }
#endif /* HAVE_PTSNAME_R */

#if defined (HAVE_PTSNAME)
    if (namebuf[0] == 0) {
	char * name;
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying ptsname()...\n");
#endif
	name = ptsname(*ptyfd);
	if (name) {
	    if(strlcpy(namebuf, name, namebuflen) >= namebuflen) {
	      warn("ERROR: IO::Tty::open_slave: ttyname truncated");
	      close(*ptyfd);
	      *ptyfd = -1;
	      return 0;
	    }
	} else {
	    if (PL_dowarn)
		warn("IO::Tty::open_slave(nonfatal): ptsname(): %.100s", strerror(errno));
	}
    }
#endif /* HAVE_PTSNAME */

    if (namebuf[0] == 0) {
	close(*ptyfd);
	*ptyfd = -1;
	return 0;		/* we failed to get the slave name */
    }

#if defined (__SVR4) && defined (__sun)
       #include <sys/types.h>
       #include <unistd.h>
       {
           uid_t euid = geteuid();
           uid_t uid  = getuid();

           /* root running as another user
            * grantpt() has done the wrong thing
             */
           if (euid != uid && uid == 0) {
#if PTY_DEBUG
		if (print_debug)
	  	    fprintf(stderr, "trying seteuid() from %d to %d...\n",
			euid, uid);
#endif
		if (setuid(uid)) {
		    warn("ERROR: IO::Tty::open_slave: couldn't seteuid to root: %d", errno);
		    close(*ptyfd);
		    *ptyfd = -1;
		    return 0;
		}
		if (chown(namebuf, euid, -1)) {
		    warn("ERROR: IO::Tty::open_slave: couldn't fchown the pty: %d", errno);
		    close(*ptyfd);
		    *ptyfd = -1;
		    return 0;
		}
		if (seteuid(euid)) {
		    warn("ERROR: IO::Tty::open_slave: couldn't seteuid back: %d", errno);
		    close(*ptyfd);
		    *ptyfd = -1;
		    return 0;
		}
           }
       }
#endif

    if (*ttyfd >= 0) {
      make_safe_fd(ptyfd);
      make_safe_fd(ttyfd);
      return 1;			/* we already have an open slave, so
                                   no more init is needed */
    }

    /*
     * Open the slave side.
     */
#if PTY_DEBUG
    if (print_debug)
      fprintf(stderr, "trying to open %s...\n", namebuf);
#endif

    *ttyfd = open(namebuf, O_RDWR | O_NOCTTY);
    if (*ttyfd < 0) {
      if (PL_dowarn)
	warn("IO::Tty::open_slave(nonfatal): open(%.200s): %.100s",
	     namebuf, strerror(errno));
      close(*ptyfd);
      *ptyfd = -1;
      return 0;		/* too bad, couldn't open slave side */
    }

#if defined (I_PUSH)
    /*
     * Push appropriate streams modules for Solaris pty(7).
     * HP-UX pty(7) doesn't have ttcompat module.
     * We simply try to push all relevant modules but warn only on
     * those platforms we know these are required.
     */
#if PTY_DEBUG
    if (print_debug)
      fprintf(stderr, "trying to I_PUSH ptem...\n");
#endif
    if (ioctl(*ttyfd, I_PUSH, "ptem") < 0)
#if defined (__solaris) || defined(__hpux)
	if (PL_dowarn)
	    warn("IO::Tty::pty_allocate: ioctl I_PUSH ptem: %.100s", strerror(errno))
#endif
	      ;

#if PTY_DEBUG
    if (print_debug)
      fprintf(stderr, "trying to I_PUSH ldterm...\n");
#endif
    if (ioctl(*ttyfd, I_PUSH, "ldterm") < 0)
#if defined (__solaris) || defined(__hpux)
	if (PL_dowarn)
	    warn("IO::Tty::pty_allocate: ioctl I_PUSH ldterm: %.100s", strerror(errno))
#endif
	      ;

#if PTY_DEBUG
    if (print_debug)
      fprintf(stderr, "trying to I_PUSH ttcompat...\n");
#endif
    if (ioctl(*ttyfd, I_PUSH, "ttcompat") < 0)
#if defined (__solaris)
	if (PL_dowarn)
	    warn("IO::Tty::pty_allocate: ioctl I_PUSH ttcompat: %.100s", strerror(errno))
#endif
	      ;
#endif /* I_PUSH */

    /* finally we make sure the filedescriptors are > 2 to avoid
       problems with stdin/out/err.  This can happen if the user
       closes one of them before allocating a pty and leads to nasty
       side-effects, so we take a proactive stance here.  Normally I
       would say "Those who mess with stdin/out/err shall bear the
       consequences to the fullest" but hey, I'm a nice guy... ;O) */

    make_safe_fd(ptyfd);
    make_safe_fd(ttyfd);

    return 1;
}

/*
 * Allocates and opens a pty.  Returns 0 if no pty could be allocated, or
 * nonzero if a pty was successfully allocated.  On success, open file
 * descriptors for the pty and tty sides and the name of the tty side are
 * returned (the buffer must be able to hold at least 64 characters).
 *
 * Instead of trying just one method we go through all available
 * methods until we get a positive result.
 */

static int
allocate_pty(int *ptyfd, int *ttyfd, char *namebuf, int namebuflen)
{
    *ptyfd = -1;
    *ttyfd = -1;
    namebuf[0] = 0;

    /*
     * first we try to get a master device
     */
    do { /* we use do{}while(0) and break instead of goto */

#if defined(HAVE__GETPTY)
	/* _getpty(3) for SGI Irix */
	{
	    char *slave;
	    mysig_t old_signal;

#if PTY_DEBUG
	    if (print_debug)
	      fprintf(stderr, "trying _getpty()...\n");
#endif
	    /* _getpty spawns a suid prog, so don't ignore SIGCHLD */
    	    old_signal = mysignal(SIGCHLD, SIG_DFL);
	    slave = _getpty(ptyfd, O_RDWR, 0622, 0);
	    mysignal(SIGCHLD, old_signal);

	    if (slave != NULL) {
	        if (strlcpy(namebuf, slave, namebuflen) >= namebuflen) {
		  warn("ERROR: pty_allocate: ttyname truncated");
		  close(*ptyfd);
		  *ptyfd = -1;
		  return 0;
		}
		if (open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		    break;
		/* open_slave closes *ptyfd on failure */
	    } else {
		if (PL_dowarn)
		    warn("pty_allocate(nonfatal): _getpty(): %.100s", strerror(errno));
		*ptyfd = -1;
	    }
	}
#endif

#if defined(HAVE_PTSNAME) || defined(HAVE_PTSNAME_R)
/* we don't need to try these if we don't have a way to get the pty names */

#if defined(HAVE_POSIX_OPENPT)
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying posix_openpt()...\n");
#endif
	*ptyfd = posix_openpt(O_RDWR|O_NOCTTY);
	if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
	    break;		/* got one */
	if (PL_dowarn)
	    warn("pty_allocate(nonfatal): posix_openpt(): %.100s", strerror(errno));
#endif /* defined(HAVE_POSIX_OPENPT) */

#if defined(HAVE_GETPT)
	/* glibc defines this */
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying getpt()...\n");
#endif
	*ptyfd = getpt();
	if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
	    break;		/* got one */
	if (PL_dowarn)
	    warn("pty_allocate(nonfatal): getpt(): %.100s", strerror(errno));
#endif /* defined(HAVE_GETPT) */

#if defined(HAVE_OPENPTY)
	/* openpty(3) exists in a variety of OS'es, but due to it's
	 * broken interface (no maxlen to slavename) we'll only use it
	 * to create the tty/pty pair and rely on ptsname to get the
	 * name.  */
	{
	    mysig_t old_signal;
	    int ret;

#if PTY_DEBUG
	    if (print_debug)
	      fprintf(stderr, "trying openpty()...\n");
#endif
	    old_signal = mysignal(SIGCHLD, SIG_DFL);
	    ret = openpty(ptyfd, ttyfd, NULL, NULL, NULL);
	    mysignal(SIGCHLD, old_signal);
	    if (ret >= 0 && *ptyfd >= 0) {
		if (open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		    break;
		/* open_slave closes *ptyfd on failure;
		   close *ttyfd which openpty() opened */
		if (*ttyfd >= 0) {
		    close(*ttyfd);
		    *ttyfd = -1;
		}
	    } else {
		*ptyfd = -1;
		*ttyfd = -1;
	    }
	    if (PL_dowarn)
		warn("pty_allocate(nonfatal): openpty(): %.100s", strerror(errno));
	}
#endif /* defined(HAVE_OPENPTY) */

	/*
	 * now try various cloning devices
	 */

#if defined(HAVE_DEV_PTMX)
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying /dev/ptmx...\n");
#endif

	*ptyfd = open("/dev/ptmx", O_RDWR | O_NOCTTY);
	if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
	    break;
	if (PL_dowarn)
	    warn("pty_allocate(nonfatal): open(/dev/ptmx): %.100s", strerror(errno));
#endif /* HAVE_DEV_PTMX */

#if defined(HAVE_DEV_PTYM_CLONE)
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying /dev/ptym/clone...\n");
#endif

	*ptyfd = open("/dev/ptym/clone", O_RDWR | O_NOCTTY);
	if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
	    break;
	if (PL_dowarn)
	    warn("pty_allocate(nonfatal): open(/dev/ptym/clone): %.100s", strerror(errno));
#endif /* HAVE_DEV_PTYM_CLONE */

#if defined(HAVE_DEV_PTC)
	/* AIX-style pty code. */
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying /dev/ptc...\n");
#endif

	*ptyfd = open("/dev/ptc", O_RDWR | O_NOCTTY);
	if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
	    break;
	if (PL_dowarn)
	    warn("pty_allocate(nonfatal): open(/dev/ptc): %.100s", strerror(errno));
#endif /* HAVE_DEV_PTC */

#if defined(HAVE_DEV_PTMX_BSD)
#if PTY_DEBUG
	if (print_debug)
	  fprintf(stderr, "trying /dev/ptmx_bsd...\n");
#endif
	*ptyfd = open("/dev/ptmx_bsd", O_RDWR | O_NOCTTY);
	if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
	    break;
	if (PL_dowarn)
	    warn("pty_allocate(nonfatal): open(/dev/ptmx_bsd): %.100s", strerror(errno));
#endif /* HAVE_DEV_PTMX_BSD */

#endif /* !defined(HAVE_PTSNAME) && !defined(HAVE_PTSNAME_R) */

	/*
	 * we still don't have a pty, so try some oldfashioned stuff,
	 * looking for a pty/tty pair ourself.
	 */

#if defined(_CRAY)
	{
	    char buf[64];
	    int i;
	    int highpty;

#ifdef _SC_CRAY_NPTY
	    highpty = sysconf(_SC_CRAY_NPTY);
	    if (highpty == -1)
		highpty = 128;
#else
	    highpty = 128;
#endif
#if PTY_DEBUG
	    if (print_debug)
	      fprintf(stderr, "trying CRAY /dev/pty/???...\n");
#endif
	    for (i = 0; i < highpty; i++) {
		snprintf(buf, sizeof(buf), "/dev/pty/%03d", i);
		*ptyfd = open(buf, O_RDWR | O_NOCTTY);
		if (*ptyfd < 0)
		    continue;
		snprintf(buf, sizeof(buf), "/dev/ttyp%03d", i);
		if (strlcpy(namebuf, buf, namebuflen) >= namebuflen) {
		  warn("ERROR: pty_allocate: ttyname truncated");
		  close(*ptyfd);
		  *ptyfd = -1;
		  return 0;
		}
		break;
	    }
	    if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		break;
	}
#endif

#if defined(HAVE_DEV_PTYM)
	{
	    /* HPUX */
	    char buf[64];
	    char tbuf[64];
	    int i;
	    struct stat sb;
	    const char *ptymajors = "abcefghijklmnopqrstuvwxyz";
	    const char *ptyminors = "0123456789abcdef";
	    int num_minors = strlen(ptyminors);
	    int num_ptys = strlen(ptymajors) * num_minors;

#if PTY_DEBUG
	    if (print_debug)
	      fprintf(stderr, "trying HPUX /dev/ptym/pty[a-ce-z][0-9a-f]...\n");
#endif
	    /* try /dev/ptym/pty[a-ce-z][0-9a-f] */
	    for (i = 0; i < num_ptys; i++) {
		snprintf(buf, sizeof(buf), "/dev/ptym/pty%c%c",
			 ptymajors[i / num_minors],
			 ptyminors[i % num_minors]);
		snprintf(tbuf, sizeof(tbuf), "/dev/pty/tty%c%c",
			 ptymajors[i / num_minors],
			 ptyminors[i % num_minors]);
		if (strlcpy(namebuf, tbuf, namebuflen) >= namebuflen) {
		  warn("ERROR: pty_allocate: ttyname truncated");
		  return 0;
		}
		if(stat(buf, &sb))
		    break;	/* file does not exist, skip rest */
		*ptyfd = open(buf, O_RDWR | O_NOCTTY);
		if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		    break;
		namebuf[0] = 0;
	    }
	    if (*ptyfd >= 0)
		break;

#if PTY_DEBUG
	    if (print_debug)
	      fprintf(stderr, "trying HPUX /dev/ptym/pty[a-ce-z][0-9][0-9]...\n");
#endif
	    /* now try /dev/ptym/pty[a-ce-z][0-9][0-9] */
	    num_minors = 100;
	    num_ptys = strlen(ptymajors) * num_minors;
	    for (i = 0; i < num_ptys; i++) {
		snprintf(buf, sizeof(buf), "/dev/ptym/pty%c%02d",
			 ptymajors[i / num_minors],
			 i % num_minors);
		snprintf(tbuf, sizeof(tbuf), "/dev/pty/tty%c%02d",
			 ptymajors[i / num_minors], i % num_minors);
		if (strlcpy(namebuf, tbuf, namebuflen) >= namebuflen) {
		  warn("ERROR: pty_allocate: ttyname truncated");
		  return 0;
		}

		if(stat(buf, &sb))
		    break;	/* file does not exist, skip rest */
		*ptyfd = open(buf, O_RDWR | O_NOCTTY);
		if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		    break;
		namebuf[0] = 0;
	    }
	    if (*ptyfd >= 0)
		break;
	}
#endif /* HAVE_DEV_PTYM */

	{
	    /* BSD-style pty code. */
	    char buf[64];
	    char tbuf[64];
	    int i;
	    const char *ptymajors = "pqrstuvwxyzabcdefghijklmnoABCDEFGHIJKLMNOPQRSTUVWXYZ";
	    const char *ptyminors = "0123456789abcdefghijklmnopqrstuv";
	    int num_minors = strlen(ptyminors);
	    int num_ptys = strlen(ptymajors) * num_minors;

#if PTY_DEBUG
	    if (print_debug)
	      fprintf(stderr, "trying BSD /dev/pty??...\n");
#endif
	    for (i = 0; i < num_ptys; i++) {
		snprintf(buf, sizeof(buf), "/dev/pty%c%c",
			ptymajors[i / num_minors],
			ptyminors[i % num_minors]);
		snprintf(tbuf, sizeof(tbuf), "/dev/tty%c%c",
			ptymajors[i / num_minors],
			ptyminors[i % num_minors]);
		if (strlcpy(namebuf, tbuf, namebuflen) >= namebuflen) {
		  warn("ERROR: pty_allocate: ttyname truncated");
		  return 0;
		}
		*ptyfd = open(buf, O_RDWR | O_NOCTTY);
		if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		    break;

		/* Try SCO style naming */
		snprintf(buf, sizeof(buf), "/dev/ptyp%d", i);
		snprintf(tbuf, sizeof(tbuf), "/dev/ttyp%d", i);
		if (strlcpy(namebuf, tbuf, namebuflen) >= namebuflen) {
		  warn("ERROR: pty_allocate: ttyname truncated");
		  return 0;
		}
		*ptyfd = open(buf, O_RDWR | O_NOCTTY);
		if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		    break;

		/* Try BeOS style naming */
		snprintf(buf, sizeof(buf), "/dev/pt/%c%c",
			ptymajors[i / num_minors],
			ptyminors[i % num_minors]);
		snprintf(tbuf, sizeof(tbuf), "/dev/tt/%c%c",
			ptymajors[i / num_minors],
			ptyminors[i % num_minors]);
		if (strlcpy(namebuf, tbuf, namebuflen) >= namebuflen) {
		  warn("ERROR: pty_allocate: ttyname truncated");
		  return 0;
		}
		*ptyfd = open(buf, O_RDWR | O_NOCTTY);
		if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		    break;

		/* Try z/OS style naming */
		snprintf(buf, sizeof(buf), "/dev/ptyp%04d", i);
		snprintf(tbuf, sizeof(tbuf), "/dev/ttyp%04d", i);
		if (strlcpy(namebuf, tbuf, namebuflen) >= namebuflen) {
		  warn("ERROR: pty_allocate: ttyname truncated");
		  return 0;
		}
		*ptyfd = open(buf, O_RDWR | O_NOCTTY);
		if (*ptyfd >= 0 && open_slave(ptyfd, ttyfd, namebuf, namebuflen))
		    break;

		namebuf[0] = 0;
	    }
	    if (*ptyfd >= 0)
		break;
	}

    } while (0);

    if (*ptyfd < 0 || namebuf[0] == 0)
	return 0;		/* we failed to allocate one */

    return 1;			/* whew, finally finished successfully */
} /* end allocate_pty */

#endif /* !HAVE_CONPTY */



MODULE = IO::Tty	PACKAGE = IO::Pty

PROTOTYPES: DISABLE

void
pty_allocate()
    INIT:
	int ptyfd, ttyfd, ret;
	char name[256];
#ifdef PTY_DEBUG
        SV *debug;
#endif

    PPCODE:
#ifdef PTY_DEBUG
        debug = get_sv("IO::Tty::DEBUG", FALSE);
  	if (SvTRUE(debug))
          print_debug = 1;
#endif
	ret = allocate_pty(&ptyfd, &ttyfd, name, sizeof(name));
	if (ret) {
	    name[sizeof(name)-1] = 0;
	    EXTEND(SP,3);
	    PUSHs(sv_2mortal(newSViv(ptyfd)));
	    PUSHs(sv_2mortal(newSViv(ttyfd)));
	    PUSHs(sv_2mortal(newSVpv(name, strlen(name))));
        } else {
	    /* empty list */
	}

#ifdef HAVE_CONPTY

void
conpty_spawn_process(master_fd, command)
	int master_fd
	const char *command
    PPCODE:
	{
	    DWORD pid = conpty_spawn(master_fd, command);
	    if (pid > 0) {
		EXTEND(SP, 1);
		PUSHs(sv_2mortal(newSVuv(pid)));
	    }
	    /* else empty list */
	}

void
conpty_resize_console(master_fd, rows, cols)
	int master_fd
	int rows
	int cols
    PPCODE:
	{
	    int ret = conpty_resize(master_fd, rows, cols);
	    EXTEND(SP, 1);
	    PUSHs(sv_2mortal(newSViv(ret)));
	}

void
conpty_close_console(master_fd)
	int master_fd
    PPCODE:
	conpty_close(master_fd);

#endif /* HAVE_CONPTY */


MODULE = IO::Tty	PACKAGE = IO::Tty

int
_open_tty(ttyname)
	char *ttyname
    CODE:
	RETVAL = open(ttyname, O_RDWR | O_NOCTTY);
	if (RETVAL >= 0) {
#if defined(I_PUSH)
	    ioctl(RETVAL, I_PUSH, "ptem");
	    ioctl(RETVAL, I_PUSH, "ldterm");
	    ioctl(RETVAL, I_PUSH, "ttcompat");
#endif
	}
    OUTPUT:
	RETVAL

char *
ttyname(fh)
    SV * fh
    CODE:
#if defined(HAVE_TTYNAME)
	{
	    IO *io = sv_2io(fh);
	    PerlIO *f = io ? IoIFP(io) : NULL;
	    if (!f && io)
		f = IoOFP(io);
	    if (f)
		RETVAL = ttyname(PerlIO_fileno(f));
	    else {
		RETVAL = NULL;
		errno = EINVAL;
	    }
	}
#elif defined(HAVE_CONPTY)
	/* On Windows, ttyname is not available; return NULL */
	RETVAL = Nullch;
#else
	warn("IO::Tty::ttyname not implemented on this architecture");
	RETVAL = NULL;
#endif
    OUTPUT:
	RETVAL

SV *
pack_winsize(row, col, xpixel = 0, ypixel = 0)
	int row
	int col
	int xpixel
	int ypixel
    INIT:
	struct winsize ws;
    CODE:
	ws.ws_row = row;
	ws.ws_col = col;
	ws.ws_xpixel = xpixel;
	ws.ws_ypixel = ypixel;
	RETVAL = newSVpvn((char *)&ws, sizeof(ws));
    OUTPUT:
	RETVAL

void
unpack_winsize(winsize)
	SV *winsize;
    INIT:
	struct winsize ws;
    PPCODE:
	if(SvCUR(winsize) != sizeof(ws))
	    croak("IO::Tty::unpack_winsize(): Bad arg length - got %zd, expected %zd",
		SvCUR(winsize), sizeof(ws));
	Copy(SvPV_nolen(winsize), &ws, sizeof(ws), char);
	EXTEND(SP, 4);
	PUSHs(sv_2mortal(newSViv(ws.ws_row)));
	PUSHs(sv_2mortal(newSViv(ws.ws_col)));
	PUSHs(sv_2mortal(newSViv(ws.ws_xpixel)));
	PUSHs(sv_2mortal(newSViv(ws.ws_ypixel)));


BOOT:
{
  HV *stash;
  SV *config;

  stash = gv_stashpv("IO::Tty::Constant", TRUE);
  config = get_sv("IO::Tty::CONFIG", TRUE);
#include "xssubs.c"
}


