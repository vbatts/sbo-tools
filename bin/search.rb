#!/usr/bin/env ruby

require 'net/ftp'
require 'tmpdir'
require 'zlib'
require 'logger'
require 'optparse'

CACHE_DIR  = '/tmp/sbo_pkgs/'
SBO_URL    = 'slackbuilds.org'
SBO_FILE   = 'SLACKBUILDS.TXT.gz'
DEF_SLACK_VERS = '13.37'

$log = Logger.new(STDERR)
$log.level = Logger::WARN

class PkgData
  SB_NAME = 'SLACKBUILD NAME: '
  SB_LOCATION = 'SLACKBUILD LOCATION: '
  SB_FILES = 'SLACKBUILD FILES: '
  SB_VERSION = 'SLACKBUILD VERSION: '
  SB_DOWNLOAD = 'SLACKBUILD DOWNLOAD: '
  SB_DOWNLOAD64 = 'SLACKBUILD DOWNLOAD_x86_64: '
  SB_MD5SUM = 'SLACKBUILD MD5SUM: '
  SB_MD5SUM64 = 'SLACKBUILD MD5SUM_x86_64: '
  SB_DESC = 'SLACKBUILD SHORT DESCRIPTION: '

  attr_accessor :name, :location, :files, :version, :download,
    :download64, :md5sum, :md5sum64, :desc
  def self.parse(blob)
    new = PkgData.new
    blob.split("\n").each do |line|
      if line.start_with? SB_NAME
	new.name = line[SB_NAME.length..-1]
      elsif line.start_with? SB_LOCATION
	new.location = line[SB_LOCATION.length..-1]
      elsif line.start_with? SB_FILES
	new.files = line[SB_FILES.length..-1].split(' ')
      elsif line.start_with? SB_VERSION
	new.version = line[SB_VERSION.length..-1]
      elsif line.start_with? SB_DOWNLOAD
	new.download = line[SB_DOWNLOAD.length..-1].split(' ')
      elsif line.start_with? SB_DOWNLOAD64
	new.download64 = line[SB_DOWNLOAD64.length..-1].split(' ')
      elsif line.start_with? SB_MD5SUM
	new.md5sum = line[SB_MD5SUM.length..-1].split(' ')
      elsif line.start_with? SB_MD5SUM64
	new.md5sum64 = line[SB_MD5SUM64.length..-1].split(' ')
      elsif line.start_with? SB_DESC
	new.desc = line[SB_DESC.length..-1]
      end
    end
    new
  end
end

def get_slack_version
  if FileTest.file? '/etc/slackware-version'
    v = File.read('/etc/slackware-version').chomp.split(' ')[1]
    v.split('.')[0..1].join('.')
  else
    DEF_SLACK_VERS
  end
end

def parse_args(args)
  options = {}
  opts = OptionParser.new do |opts|
    opts.on('-k KEYWORD','search the descriptions for KEYWORD') do |o|
      options[:desc_key] = o
    end
    opts.on('-g KEYWORD', 'search package names for KEYWORD') do |o|
      options[:name_key] = o
    end
    opts.on('-r', 'check and refresh cache') do |o|
      options[:refresh] = o
    end
    opts.on('-v', 'verbose') do |o|
      options[:verbose] = o
    end
  end
  opts.parse!(args)
  options
end

def check_dir
  Dir.mkdir(CACHE_DIR) unless FileTest.directory? CACHE_DIR
end

def cache_path
  File.join(CACHE_DIR, SBO_FILE)
end

def refresh_cache()
  check_dir()

  @prev_mtime = if FileTest.file? cache_path
		  t = File.mtime(cache_path)
		  $log.info(cache_path) { 'mtime: ' + t.to_i.to_s }
		  t
		else
		  $log.info(cache_path) { 'file does not exist' }
		  nil
		end

  Dir.chdir(CACHE_DIR) do
    Net::FTP.open(SBO_URL) do |ftp|
      $log.debug { 'opened ' + SBO_URL }

      $log.debug { 'ftp login ' }
      ftp.login

      begin
	v = get_slack_version()
	$log.debug { 'cd ' + v }
	ftp.chdir(v)
      rescue Net::FTPPermError
	$log.debug { 'cd ' + DEF_SLACK_VERS }
	ftp.chdir(DEF_SLACK_VERS)
      end

      @mtime = ftp.mtime(SBO_FILE)
      $log.info('mtime') { @mtime }

      if not @prev_mtime or (@prev_mtime < @mtime)
	$log.info { 'fetching ' + SBO_FILE }
	ftp.getbinaryfile(SBO_FILE, SBO_FILE, 1024)
	$log.info { 'fetched ' + SBO_FILE }
      end
    end
  end

  File.utime(@mtime, @mtime, cache_path)
end

def read_pkgs
  return [] unless FileTest.file? cache_path

  gz_file = Zlib::GzipReader.open(cache_path)
  pkg_blobs = gz_file.read().split("\n\n")
  pkgs = if pkg_blobs.length > 0
	    pkg_blobs.map {|blob| PkgData.parse(blob) }
	  else
	    []
	  end
  return pkgs
end

if $0 == __FILE__
  options = parse_args(ARGV)
  $log.level = Logger::DEBUG if options[:verbose]

  if options[:refresh]
    refresh_cache()
  end
  
  @pkgs = read_pkgs()

  if options[:desc_key]
    @pkgs.each do |pkg|
      if pkg.desc =~ /#{options[:desc_key]}/i
	puts "#{pkg.name} :: #{pkg.desc}"
      end
    end
  elsif options[:name_key]
    @pkgs.each do |pkg|
      if pkg.name =~ /#{options[:name_key]}/i
	puts "#{pkg.name} :: #{pkg.desc}"
      end
    end
  end
end

# vim: set nu sw=2 sts=2 noet :
