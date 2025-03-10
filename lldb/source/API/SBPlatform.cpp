//===-- SBPlatform.cpp ----------------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "lldb/API/SBPlatform.h"
#include "lldb/Utility/ReproducerInstrumentation.h"
#include "lldb/API/SBEnvironment.h"
#include "lldb/API/SBError.h"
#include "lldb/API/SBFileSpec.h"
#include "lldb/API/SBLaunchInfo.h"
#include "lldb/API/SBPlatform.h"
#include "lldb/API/SBUnixSignals.h"
#include "lldb/Host/File.h"
#include "lldb/Target/Platform.h"
#include "lldb/Target/Target.h"
#include "lldb/Utility/ArchSpec.h"
#include "lldb/Utility/Args.h"
#include "lldb/Utility/Status.h"

#include "llvm/Support/FileSystem.h"

#include <functional>

using namespace lldb;
using namespace lldb_private;

// PlatformConnectOptions
struct PlatformConnectOptions {
  PlatformConnectOptions(const char *url = nullptr) {
    if (url && url[0])
      m_url = url;
  }

  ~PlatformConnectOptions() = default;

  std::string m_url;
  std::string m_rsync_options;
  std::string m_rsync_remote_path_prefix;
  bool m_rsync_enabled = false;
  bool m_rsync_omit_hostname_from_remote_path = false;
  ConstString m_local_cache_directory;
};

// PlatformShellCommand
struct PlatformShellCommand {
  PlatformShellCommand(llvm::StringRef shell_interpreter,
                       llvm::StringRef shell_command)
      : m_status(0), m_signo(0) {
    if (!shell_interpreter.empty())
      m_shell = shell_interpreter.str();

    if (!m_shell.empty() && !shell_command.empty())
      m_command = shell_command.str();
  }

  PlatformShellCommand(llvm::StringRef shell_command = llvm::StringRef()) {
    if (!shell_command.empty())
      m_command = shell_command.str();
  }

  ~PlatformShellCommand() = default;

  std::string m_shell;
  std::string m_command;
  std::string m_working_dir;
  std::string m_output;
  int m_status = 0;
  int m_signo = 0;
  Timeout<std::ratio<1>> m_timeout = llvm::None;
};
// SBPlatformConnectOptions
SBPlatformConnectOptions::SBPlatformConnectOptions(const char *url)
    : m_opaque_ptr(new PlatformConnectOptions(url)) {
  LLDB_RECORD_CONSTRUCTOR(SBPlatformConnectOptions, (const char *), url);
}

SBPlatformConnectOptions::SBPlatformConnectOptions(
    const SBPlatformConnectOptions &rhs)
    : m_opaque_ptr(new PlatformConnectOptions()) {
  LLDB_RECORD_CONSTRUCTOR(SBPlatformConnectOptions,
                          (const lldb::SBPlatformConnectOptions &), rhs);

  *m_opaque_ptr = *rhs.m_opaque_ptr;
}

SBPlatformConnectOptions::~SBPlatformConnectOptions() { delete m_opaque_ptr; }

SBPlatformConnectOptions &
SBPlatformConnectOptions::operator=(const SBPlatformConnectOptions &rhs) {
  LLDB_RECORD_METHOD(
      SBPlatformConnectOptions &,
      SBPlatformConnectOptions, operator=,(
                                    const lldb::SBPlatformConnectOptions &),
      rhs);

  *m_opaque_ptr = *rhs.m_opaque_ptr;
  return *this;
}

const char *SBPlatformConnectOptions::GetURL() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatformConnectOptions, GetURL);

  if (m_opaque_ptr->m_url.empty())
    return nullptr;
  return m_opaque_ptr->m_url.c_str();
}

void SBPlatformConnectOptions::SetURL(const char *url) {
  LLDB_RECORD_METHOD(void, SBPlatformConnectOptions, SetURL, (const char *),
                     url);

  if (url && url[0])
    m_opaque_ptr->m_url = url;
  else
    m_opaque_ptr->m_url.clear();
}

bool SBPlatformConnectOptions::GetRsyncEnabled() {
  LLDB_RECORD_METHOD_NO_ARGS(bool, SBPlatformConnectOptions, GetRsyncEnabled);

  return m_opaque_ptr->m_rsync_enabled;
}

void SBPlatformConnectOptions::EnableRsync(
    const char *options, const char *remote_path_prefix,
    bool omit_hostname_from_remote_path) {
  LLDB_RECORD_METHOD(void, SBPlatformConnectOptions, EnableRsync,
                     (const char *, const char *, bool), options,
                     remote_path_prefix, omit_hostname_from_remote_path);

  m_opaque_ptr->m_rsync_enabled = true;
  m_opaque_ptr->m_rsync_omit_hostname_from_remote_path =
      omit_hostname_from_remote_path;
  if (remote_path_prefix && remote_path_prefix[0])
    m_opaque_ptr->m_rsync_remote_path_prefix = remote_path_prefix;
  else
    m_opaque_ptr->m_rsync_remote_path_prefix.clear();

  if (options && options[0])
    m_opaque_ptr->m_rsync_options = options;
  else
    m_opaque_ptr->m_rsync_options.clear();
}

void SBPlatformConnectOptions::DisableRsync() {
  LLDB_RECORD_METHOD_NO_ARGS(void, SBPlatformConnectOptions, DisableRsync);

  m_opaque_ptr->m_rsync_enabled = false;
}

const char *SBPlatformConnectOptions::GetLocalCacheDirectory() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatformConnectOptions,
                             GetLocalCacheDirectory);

  return m_opaque_ptr->m_local_cache_directory.GetCString();
}

void SBPlatformConnectOptions::SetLocalCacheDirectory(const char *path) {
  LLDB_RECORD_METHOD(void, SBPlatformConnectOptions, SetLocalCacheDirectory,
                     (const char *), path);

  if (path && path[0])
    m_opaque_ptr->m_local_cache_directory.SetCString(path);
  else
    m_opaque_ptr->m_local_cache_directory = ConstString();
}

// SBPlatformShellCommand
SBPlatformShellCommand::SBPlatformShellCommand(const char *shell_interpreter,
                                               const char *shell_command)
    : m_opaque_ptr(new PlatformShellCommand(shell_interpreter, shell_command)) {
  LLDB_RECORD_CONSTRUCTOR(SBPlatformShellCommand, (const char *, const char *),
                          shell_interpreter, shell_command);
}

SBPlatformShellCommand::SBPlatformShellCommand(const char *shell_command)
    : m_opaque_ptr(new PlatformShellCommand(shell_command)) {
  LLDB_RECORD_CONSTRUCTOR(SBPlatformShellCommand, (const char *),
                          shell_command);
}

SBPlatformShellCommand::SBPlatformShellCommand(
    const SBPlatformShellCommand &rhs)
    : m_opaque_ptr(new PlatformShellCommand()) {
  LLDB_RECORD_CONSTRUCTOR(SBPlatformShellCommand,
                          (const lldb::SBPlatformShellCommand &), rhs);

  *m_opaque_ptr = *rhs.m_opaque_ptr;
}

SBPlatformShellCommand &
SBPlatformShellCommand::operator=(const SBPlatformShellCommand &rhs) {

  LLDB_RECORD_METHOD(
      SBPlatformShellCommand &,
      SBPlatformShellCommand, operator=,(const lldb::SBPlatformShellCommand &),
      rhs);

  *m_opaque_ptr = *rhs.m_opaque_ptr;
  return *this;
}

SBPlatformShellCommand::~SBPlatformShellCommand() { delete m_opaque_ptr; }

void SBPlatformShellCommand::Clear() {
  LLDB_RECORD_METHOD_NO_ARGS(void, SBPlatformShellCommand, Clear);

  m_opaque_ptr->m_output = std::string();
  m_opaque_ptr->m_status = 0;
  m_opaque_ptr->m_signo = 0;
}

const char *SBPlatformShellCommand::GetShell() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatformShellCommand, GetShell);

  if (m_opaque_ptr->m_shell.empty())
    return nullptr;
  return m_opaque_ptr->m_shell.c_str();
}

void SBPlatformShellCommand::SetShell(const char *shell_interpreter) {
  LLDB_RECORD_METHOD(void, SBPlatformShellCommand, SetShell, (const char *),
                     shell_interpreter);

  if (shell_interpreter && shell_interpreter[0])
    m_opaque_ptr->m_shell = shell_interpreter;
  else
    m_opaque_ptr->m_shell.clear();
}

const char *SBPlatformShellCommand::GetCommand() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatformShellCommand, GetCommand);

  if (m_opaque_ptr->m_command.empty())
    return nullptr;
  return m_opaque_ptr->m_command.c_str();
}

void SBPlatformShellCommand::SetCommand(const char *shell_command) {
  LLDB_RECORD_METHOD(void, SBPlatformShellCommand, SetCommand, (const char *),
                     shell_command);

  if (shell_command && shell_command[0])
    m_opaque_ptr->m_command = shell_command;
  else
    m_opaque_ptr->m_command.clear();
}

const char *SBPlatformShellCommand::GetWorkingDirectory() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatformShellCommand,
                             GetWorkingDirectory);

  if (m_opaque_ptr->m_working_dir.empty())
    return nullptr;
  return m_opaque_ptr->m_working_dir.c_str();
}

void SBPlatformShellCommand::SetWorkingDirectory(const char *path) {
  LLDB_RECORD_METHOD(void, SBPlatformShellCommand, SetWorkingDirectory,
                     (const char *), path);

  if (path && path[0])
    m_opaque_ptr->m_working_dir = path;
  else
    m_opaque_ptr->m_working_dir.clear();
}

uint32_t SBPlatformShellCommand::GetTimeoutSeconds() {
  LLDB_RECORD_METHOD_NO_ARGS(uint32_t, SBPlatformShellCommand,
                             GetTimeoutSeconds);

  if (m_opaque_ptr->m_timeout)
    return m_opaque_ptr->m_timeout->count();
  return UINT32_MAX;
}

void SBPlatformShellCommand::SetTimeoutSeconds(uint32_t sec) {
  LLDB_RECORD_METHOD(void, SBPlatformShellCommand, SetTimeoutSeconds,
                     (uint32_t), sec);

  if (sec == UINT32_MAX)
    m_opaque_ptr->m_timeout = llvm::None;
  else
    m_opaque_ptr->m_timeout = std::chrono::seconds(sec);
}

int SBPlatformShellCommand::GetSignal() {
  LLDB_RECORD_METHOD_NO_ARGS(int, SBPlatformShellCommand, GetSignal);

  return m_opaque_ptr->m_signo;
}

int SBPlatformShellCommand::GetStatus() {
  LLDB_RECORD_METHOD_NO_ARGS(int, SBPlatformShellCommand, GetStatus);

  return m_opaque_ptr->m_status;
}

const char *SBPlatformShellCommand::GetOutput() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatformShellCommand, GetOutput);

  if (m_opaque_ptr->m_output.empty())
    return nullptr;
  return m_opaque_ptr->m_output.c_str();
}

// SBPlatform
SBPlatform::SBPlatform() { LLDB_RECORD_CONSTRUCTOR_NO_ARGS(SBPlatform); }

SBPlatform::SBPlatform(const char *platform_name) {
  LLDB_RECORD_CONSTRUCTOR(SBPlatform, (const char *), platform_name);

  Status error;
  if (platform_name && platform_name[0])
    m_opaque_sp = Platform::Create(ConstString(platform_name), error);
}

SBPlatform::SBPlatform(const SBPlatform &rhs) {
  LLDB_RECORD_CONSTRUCTOR(SBPlatform, (const lldb::SBPlatform &), rhs);

  m_opaque_sp = rhs.m_opaque_sp;
}

SBPlatform &SBPlatform::operator=(const SBPlatform &rhs) {
  LLDB_RECORD_METHOD(SBPlatform &,
                     SBPlatform, operator=,(const lldb::SBPlatform &), rhs);

  m_opaque_sp = rhs.m_opaque_sp;
  return *this;
}

SBPlatform::~SBPlatform() = default;

SBPlatform SBPlatform::GetHostPlatform() {
  LLDB_RECORD_STATIC_METHOD_NO_ARGS(lldb::SBPlatform, SBPlatform,
                                    GetHostPlatform);

  SBPlatform host_platform;
  host_platform.m_opaque_sp = Platform::GetHostPlatform();
  return host_platform;
}

bool SBPlatform::IsValid() const {
  LLDB_RECORD_METHOD_CONST_NO_ARGS(bool, SBPlatform, IsValid);
  return this->operator bool();
}
SBPlatform::operator bool() const {
  LLDB_RECORD_METHOD_CONST_NO_ARGS(bool, SBPlatform, operator bool);

  return m_opaque_sp.get() != nullptr;
}

void SBPlatform::Clear() {
  LLDB_RECORD_METHOD_NO_ARGS(void, SBPlatform, Clear);

  m_opaque_sp.reset();
}

const char *SBPlatform::GetName() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatform, GetName);

  PlatformSP platform_sp(GetSP());
  if (platform_sp)
    return platform_sp->GetName().GetCString();
  return nullptr;
}

lldb::PlatformSP SBPlatform::GetSP() const { return m_opaque_sp; }

void SBPlatform::SetSP(const lldb::PlatformSP &platform_sp) {
  m_opaque_sp = platform_sp;
}

const char *SBPlatform::GetWorkingDirectory() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatform, GetWorkingDirectory);

  PlatformSP platform_sp(GetSP());
  if (platform_sp)
    return platform_sp->GetWorkingDirectory().GetCString();
  return nullptr;
}

bool SBPlatform::SetWorkingDirectory(const char *path) {
  LLDB_RECORD_METHOD(bool, SBPlatform, SetWorkingDirectory, (const char *),
                     path);

  PlatformSP platform_sp(GetSP());
  if (platform_sp) {
    if (path)
      platform_sp->SetWorkingDirectory(FileSpec(path));
    else
      platform_sp->SetWorkingDirectory(FileSpec());
    return true;
  }
  return false;
}

SBError SBPlatform::ConnectRemote(SBPlatformConnectOptions &connect_options) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, ConnectRemote,
                     (lldb::SBPlatformConnectOptions &), connect_options);

  SBError sb_error;
  PlatformSP platform_sp(GetSP());
  if (platform_sp && connect_options.GetURL()) {
    Args args;
    args.AppendArgument(connect_options.GetURL());
    sb_error.ref() = platform_sp->ConnectRemote(args);
  } else {
    sb_error.SetErrorString("invalid platform");
  }
  return sb_error;
}

void SBPlatform::DisconnectRemote() {
  LLDB_RECORD_METHOD_NO_ARGS(void, SBPlatform, DisconnectRemote);

  PlatformSP platform_sp(GetSP());
  if (platform_sp)
    platform_sp->DisconnectRemote();
}

bool SBPlatform::IsConnected() {
  LLDB_RECORD_METHOD_NO_ARGS(bool, SBPlatform, IsConnected);

  PlatformSP platform_sp(GetSP());
  if (platform_sp)
    return platform_sp->IsConnected();
  return false;
}

const char *SBPlatform::GetTriple() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatform, GetTriple);

  PlatformSP platform_sp(GetSP());
  if (platform_sp) {
    ArchSpec arch(platform_sp->GetSystemArchitecture());
    if (arch.IsValid()) {
      // Const-ify the string so we don't need to worry about the lifetime of
      // the string
      return ConstString(arch.GetTriple().getTriple().c_str()).GetCString();
    }
  }
  return nullptr;
}

const char *SBPlatform::GetOSBuild() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatform, GetOSBuild);

  PlatformSP platform_sp(GetSP());
  if (platform_sp) {
    std::string s = platform_sp->GetOSBuildString().getValueOr("");
    if (!s.empty()) {
      // Const-ify the string so we don't need to worry about the lifetime of
      // the string
      return ConstString(s).GetCString();
    }
  }
  return nullptr;
}

const char *SBPlatform::GetOSDescription() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatform, GetOSDescription);

  PlatformSP platform_sp(GetSP());
  if (platform_sp) {
    std::string s = platform_sp->GetOSKernelDescription().getValueOr("");
    if (!s.empty()) {
      // Const-ify the string so we don't need to worry about the lifetime of
      // the string
      return ConstString(s.c_str()).GetCString();
    }
  }
  return nullptr;
}

const char *SBPlatform::GetHostname() {
  LLDB_RECORD_METHOD_NO_ARGS(const char *, SBPlatform, GetHostname);

  PlatformSP platform_sp(GetSP());
  if (platform_sp)
    return platform_sp->GetHostname();
  return nullptr;
}

uint32_t SBPlatform::GetOSMajorVersion() {
  LLDB_RECORD_METHOD_NO_ARGS(uint32_t, SBPlatform, GetOSMajorVersion);

  llvm::VersionTuple version;
  if (PlatformSP platform_sp = GetSP())
    version = platform_sp->GetOSVersion();
  return version.empty() ? UINT32_MAX : version.getMajor();
}

uint32_t SBPlatform::GetOSMinorVersion() {
  LLDB_RECORD_METHOD_NO_ARGS(uint32_t, SBPlatform, GetOSMinorVersion);

  llvm::VersionTuple version;
  if (PlatformSP platform_sp = GetSP())
    version = platform_sp->GetOSVersion();
  return version.getMinor().getValueOr(UINT32_MAX);
}

uint32_t SBPlatform::GetOSUpdateVersion() {
  LLDB_RECORD_METHOD_NO_ARGS(uint32_t, SBPlatform, GetOSUpdateVersion);

  llvm::VersionTuple version;
  if (PlatformSP platform_sp = GetSP())
    version = platform_sp->GetOSVersion();
  return version.getSubminor().getValueOr(UINT32_MAX);
}

void SBPlatform::SetSDKRoot(const char *sysroot) {
  LLDB_RECORD_METHOD(void, SBPlatform, SetSDKRoot, (const char *), sysroot);
  if (PlatformSP platform_sp = GetSP())
    platform_sp->SetSDKRootDirectory(ConstString(sysroot));
}

SBError SBPlatform::Get(SBFileSpec &src, SBFileSpec &dst) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, Get,
                     (lldb::SBFileSpec &, lldb::SBFileSpec &), src, dst);

  SBError sb_error;
  PlatformSP platform_sp(GetSP());
  if (platform_sp) {
    sb_error.ref() = platform_sp->GetFile(src.ref(), dst.ref());
  } else {
    sb_error.SetErrorString("invalid platform");
  }
  return sb_error;
}

SBError SBPlatform::Put(SBFileSpec &src, SBFileSpec &dst) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, Put,
                     (lldb::SBFileSpec &, lldb::SBFileSpec &), src, dst);
  return ExecuteConnected([&](const lldb::PlatformSP &platform_sp) {
    if (src.Exists()) {
      uint32_t permissions = FileSystem::Instance().GetPermissions(src.ref());
      if (permissions == 0) {
        if (FileSystem::Instance().IsDirectory(src.ref()))
          permissions = eFilePermissionsDirectoryDefault;
        else
          permissions = eFilePermissionsFileDefault;
      }

      return platform_sp->PutFile(src.ref(), dst.ref(), permissions);
    }

    Status error;
    error.SetErrorStringWithFormat("'src' argument doesn't exist: '%s'",
                                   src.ref().GetPath().c_str());
    return error;
  });
}

SBError SBPlatform::Install(SBFileSpec &src, SBFileSpec &dst) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, Install,
                     (lldb::SBFileSpec &, lldb::SBFileSpec &), src, dst);
  return ExecuteConnected([&](const lldb::PlatformSP &platform_sp) {
    if (src.Exists())
      return platform_sp->Install(src.ref(), dst.ref());

    Status error;
    error.SetErrorStringWithFormat("'src' argument doesn't exist: '%s'",
                                   src.ref().GetPath().c_str());
    return error;
  });
}

SBError SBPlatform::Run(SBPlatformShellCommand &shell_command) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, Run,
                     (lldb::SBPlatformShellCommand &), shell_command);
  return ExecuteConnected(
      [&](const lldb::PlatformSP &platform_sp) {
        const char *command = shell_command.GetCommand();
        if (!command)
          return Status("invalid shell command (empty)");

        const char *working_dir = shell_command.GetWorkingDirectory();
        if (working_dir == nullptr) {
          working_dir = platform_sp->GetWorkingDirectory().GetCString();
          if (working_dir)
            shell_command.SetWorkingDirectory(working_dir);
        }
        return platform_sp->RunShellCommand(
            shell_command.m_opaque_ptr->m_shell, command, FileSpec(working_dir),
            &shell_command.m_opaque_ptr->m_status,
            &shell_command.m_opaque_ptr->m_signo,
            &shell_command.m_opaque_ptr->m_output,
            shell_command.m_opaque_ptr->m_timeout);
      });
}

SBError SBPlatform::Launch(SBLaunchInfo &launch_info) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, Launch, (lldb::SBLaunchInfo &),
                     launch_info);
  return ExecuteConnected([&](const lldb::PlatformSP &platform_sp) {
    ProcessLaunchInfo info = launch_info.ref();
    Status error = platform_sp->LaunchProcess(info);
    launch_info.set_ref(info);
    return error;
  });
}

SBError SBPlatform::Kill(const lldb::pid_t pid) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, Kill, (const lldb::pid_t), pid);
  return ExecuteConnected([&](const lldb::PlatformSP &platform_sp) {
    return platform_sp->KillProcess(pid);
  });
}

SBError SBPlatform::ExecuteConnected(
    const std::function<Status(const lldb::PlatformSP &)> &func) {
  SBError sb_error;
  const auto platform_sp(GetSP());
  if (platform_sp) {
    if (platform_sp->IsConnected())
      sb_error.ref() = func(platform_sp);
    else
      sb_error.SetErrorString("not connected");
  } else
    sb_error.SetErrorString("invalid platform");

  return sb_error;
}

SBError SBPlatform::MakeDirectory(const char *path, uint32_t file_permissions) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, MakeDirectory,
                     (const char *, uint32_t), path, file_permissions);

  SBError sb_error;
  PlatformSP platform_sp(GetSP());
  if (platform_sp) {
    sb_error.ref() =
        platform_sp->MakeDirectory(FileSpec(path), file_permissions);
  } else {
    sb_error.SetErrorString("invalid platform");
  }
  return sb_error;
}

uint32_t SBPlatform::GetFilePermissions(const char *path) {
  LLDB_RECORD_METHOD(uint32_t, SBPlatform, GetFilePermissions, (const char *),
                     path);

  PlatformSP platform_sp(GetSP());
  if (platform_sp) {
    uint32_t file_permissions = 0;
    platform_sp->GetFilePermissions(FileSpec(path), file_permissions);
    return file_permissions;
  }
  return 0;
}

SBError SBPlatform::SetFilePermissions(const char *path,
                                       uint32_t file_permissions) {
  LLDB_RECORD_METHOD(lldb::SBError, SBPlatform, SetFilePermissions,
                     (const char *, uint32_t), path, file_permissions);

  SBError sb_error;
  PlatformSP platform_sp(GetSP());
  if (platform_sp) {
    sb_error.ref() =
        platform_sp->SetFilePermissions(FileSpec(path), file_permissions);
  } else {
    sb_error.SetErrorString("invalid platform");
  }
  return sb_error;
}

SBUnixSignals SBPlatform::GetUnixSignals() const {
  LLDB_RECORD_METHOD_CONST_NO_ARGS(lldb::SBUnixSignals, SBPlatform,
                                   GetUnixSignals);

  if (auto platform_sp = GetSP())
    return SBUnixSignals{platform_sp};

  return SBUnixSignals();
}

SBEnvironment SBPlatform::GetEnvironment() {
  LLDB_RECORD_METHOD_NO_ARGS(lldb::SBEnvironment, SBPlatform, GetEnvironment);
  PlatformSP platform_sp(GetSP());

  if (platform_sp) {
    return SBEnvironment(platform_sp->GetEnvironment());
  }

  return SBEnvironment();
}
