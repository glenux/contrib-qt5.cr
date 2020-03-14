#!/usr/bin/env crystal

# This script downloads all sources of all supported Qt5 versions, and then
# proceed to generate all bindings for all configured platforms.
#
# This script is what the `ready-to-use` branches are built by.

require "file_utils"
require "colorize"
require "ini"
require "file"

configurations = [
#      OS       LIBC   ARCH      Qt     Clang target triplet      Ptr  Endian
#  { "linux", "gnu", "x86_64", "5.5",  "x86_64-unknown-linux-gnu", 8, "little" },
#  { "linux", "gnu", "x86_64", "5.6",  "x86_64-unknown-linux-gnu", 8, "little" },
#  { "linux", "gnu", "x86_64", "5.7",  "x86_64-unknown-linux-gnu", 8, "little" },
#  { "linux", "gnu", "x86_64", "5.8",  "x86_64-unknown-linux-gnu", 8, "little" },
#  { "linux", "gnu", "x86_64", "5.9",  "x86_64-unknown-linux-gnu", 8, "little" },
#  { "linux", "gnu", "x86_64", "5.10", "x86_64-unknown-linux-gnu", 8, "little" },
#  { "linux", "gnu", "x86_64", "5.12", "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.12.3", "x86_64-unknown-linux-gnu", 8, "little" },
]

TEMPDIR = File.expand_path("#{__DIR__}/../download_cache")

struct QtVersion
  getter name : String
  getter major : Int32
  getter minor : Int32
  getter patch : Int32
  delegate to_s, to: @name

  def initialize(@name)
    @major, @minor, @patch = (@name.split(/\./).map(&.to_i) + [0])[0..2]
  end

  def semver_short
    "#{@major}.#{@minor}"
  end

  def semver
    "#{@major}.#{@minor}.#{@patch}"
  end

  def download_url
    if @major == 5 && @minor >= 12
      "https://download.qt.io/archive/qt/#{semver_short}/#{semver}/single/qt-everywhere-src-#{semver}.tar.xz"
    else
      "https://download.qt.io/archive/qt/#{semver_short}/#{semver}/single/qt-everywhere-opensource-src-#{semver}.tar.xz"
    end
  end

  def archive_path
    if @major == 5 && @minor >= 12
      "#{TEMPDIR}/qt-everywhere-src-#{semver}.tar.xz"
    else
      "#{TEMPDIR}/qt-everywhere-opensource-src-#{semver}.tar.xz"
    end
  end

  def path
    if @major == 5 && @minor >= 12
      "#{TEMPDIR}/qt-everywhere-src-#{semver}"
    else
      "#{TEMPDIR}/qt-everywhere-opensource-src-#{semver}"
    end
  end
end

class TargetPlatform
  getter os : String
  getter libc : String
  getter arch : String
  getter qt : QtVersion
  getter triple : String
  getter pointer_size : Int32
  getter endian : String

  def initialize(@os, @libc, @arch, qt, @triple, @pointer_size, @endian)
    @qt = QtVersion.new(qt)
  end

  def target
    "#{@os}-#{@libc}-#{@arch}-qt#{@qt}"
  end
end

def report(current, total, message)
  cur_s = (current + 1).to_s
  total_s = total.to_s

  step_s = "#{cur_s.ljust(total_s.size)}/#{total_s}".colorize.mode(:bold)
  puts "(#{step_s})  #{message}"
end

def report_step(message)
  puts "=> #{message}".colorize.mode(:bold)
end

def download_missing_qts(versions)
  missing_versions = versions
    .reject{|v| File.file? v.archive_path}

  if missing_versions.empty?
    report_step "All Qt sources already present"
    return
  end

  report_step "Downloading missing Qt sources"
  missing_versions.each_with_index do |v, idx|
    url = v.download_url
    destfile =  Path[url].basename
    partfile =  destfile + ".part"
    arguments = [ 
      "--continue-at", "-", 
      "--remote-name-all", 
      "--location",
      "--output", partfile,
      url
    ] 

    report(idx, missing_versions.size, "Downloading sources for version #{v.semver}")

    
    retry = 3
    while retry > 0
      Dir.cd TEMPDIR do
        system("curl", arguments)
      end

      if $?.exit_code == 56 || $?.exit_code == 18
        # the download was interrupted by remote party (retry 3 times)
        retry = retry - 1
      elsif $?.exit_code == 0
        retry = 0
      else
        STDERR.puts "Failed to download Qt source for version #{v.semver} from #{url}"
        exit 2
      end
    end

    Dir.cd TEMPDIR do
      FileUtils.mv partfile, destfile
    end
  end


end

def unpack_qts(versions)
  remaining_files = versions
    .reject{|v| Dir.exists? v.path}

  if remaining_files.empty?
    report_step "All Qt sources already unpacked"
    return
  end

  report_step "Unpacking Qt sources"
  remaining_files.each_with_index do |version, idx|
    file = version.archive_path
    report(idx, remaining_files.size, "Unpacking Qt version #{version.semver}")
    system("tar", [ "-C", TEMPDIR, "-xaf", file ])

    unless $?.success?
      STDERR.puts "Failed to unpack Qt source for version #{version.semver} from #{file}"
      exit 2
    end
  end
end

def get_qt_modules_from_gitmodules(version)
  # This is actually how they're aggregating which modules exist in `qt.pro`
  modules_file = "#{version.path}/.gitmodules"

  if File.exists? modules_file
    data = INI.parse File.read(modules_file)
    data
      .reject{|_, v| v["qt"]? == "false"}
      .map{|k, _| k[/submodule "qt(.*)"/, 1]?}
  end
end

def get_qt_modules_from_qtpro(version)
  # For Qt5.5 and below
  pro_file = "#{version.path}/qt.pro"

  if File.exists? pro_file
    File.read_lines(pro_file)
      .grep(/^addModule\(qt/)
      .map{|x| x[/addModule\(qt([^,)]+)/, 1]?}
      .to_a
  end
end

def get_qt_modules(version) : Array(String)
  modules = get_qt_modules_from_gitmodules(version)
  modules ||= get_qt_modules_from_qtpro(version)

  if modules
    modules
      .compact
      .select{|name| Dir.exists?("#{version.path}/qt#{name}")}
  else
    Array(String).new
  end
end

def configure_qts(versions)
  keep_modules = { "base" }
  list = versions.reject{|v| File.executable? "#{v.path}/qtbase/bin/qmake"}

  if list.empty?
    report_step "All Qt sources already configured"
    return
  end

  report_step "Configuring Qt versions"
  list.each_with_index do |qt, idx|
    report(idx, list.size, "Configuring Qt #{qt.semver}")

    skip_modules = get_qt_modules(qt).reject{|x| keep_modules.includes? x}
    skip_args = skip_modules.flat_map{|x| [ "-skip", x ]}

    Dir.cd qt.path do
      system( # Build QMake of this version
        "./configure",
        [
          "-opensource", "-confirm-license",
          "-nomake", "examples",
          "-nomake", "tests",
          "-nomake", "tools",
          "-prefix", "#{qt.path}/qtbase",
        ] + skip_args,
      )

      unless $?.success?
        STDERR.puts "Failed to configure Qt#{qt} in #{qt.path} - Abort."
        exit 2
      end
    end

    # Use QMake to generate all missing include files
    system("make", [ "-C", qt.path, "qmake_all" ])

    unless $?.success?
      STDERR.puts "Failed to generate headers for Qt#{qt} in #{qt.path} - Abort."
      exit 2
    end
  end
end

# Kick off
FileUtils.mkdir_p(TEMPDIR)
platforms = configurations.map{|x| TargetPlatform.new(*x)}
versions = platforms.map(&.qt).uniq

# Download and unpack Qt sources
download_missing_qts(versions)
unpack_qts(versions)
configure_qts(versions)

# Run bindgen for all configured platforms
report_step "Generating bindings for all platforms"
platforms.each_with_index do |platform, idx|
  env = { # Set environment variables for `config/find_paths.yml`
    "QTDIR" => platform.qt.path,
    "QMAKE" => "#{platform.qt.path}/qtbase/bin/qmake",
    # "QT_INCLUDE_DIR" => Auto configured,
    "QT_LIBS_DIR" => "#{platform.qt.path}/qtbase/libs",
    "TARGET_TRIPLE" => platform.triple,
    "BINDING_PLATFORM" => platform.target,
  }

  args = [ # Arguments to bindgen
    "qt.yml",
    "--var", "architecture=#{platform.arch}",
    "--var", "libc=#{platform.libc}",
    "--var", "os=#{platform.os}",
    "--var", "pointersize=#{platform.pointer_size}",
    "--var", "endian=#{platform.endian}",
  ]

  report(idx, platforms.size, "Generating #{platform.target}")
  bindgen = Process.run( # Run bindgen
    command: "lib/bindgen/tool.sh",
    args: args,
    env: env,
    shell: false,
    output: STDOUT,
    error: STDERR,
  )

  unless bindgen.success?
    STDERR.puts "Failed to build #{platform.target} using Qt#{platform.qt} on #{platform.triple} - Abort."
    exit 1
  end
end
