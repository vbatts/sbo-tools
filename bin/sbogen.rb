#!/usr/bin/env ruby

require 'optparse'
require 'digest/md5'
require 'fileutils'

module SBo
        SBO_CONFIG_FILE   = "/etc/sbopkg/sbopkg.conf"
        SBO_RSYNC_PATH    = "rsync://slackbuilds.org/slackbuilds/"
        @config = {}

        def parse_config()
                data = Hash.new
                info = File.read(SBO_CONFIG_FILE).gsub(/\\\n/, " ").split("\n")
                for line in info
                        # cleanup stuffs
                        line = line.split("#")[0]
                        next if line.nil? or line.empty?
                        line.strip!
                        line = line.gsub(/\"/,'')
                        if line.start_with?("export ")
                                line = line.sub(/export\s*/, "")
                        end

                        key, value = line.split("=",2)
                        data[key] = value.split(":-")[1][0..-2]
                end
                return data
        end
        module_function :parse_config

        def build_config()
                @config = parse_config()
        end
        module_function :build_config

        def repo_dir
                build_config() if @config.empty?
                return File.join(@config["REPO_ROOT"], @config["REPO_NAME"], @config["REPO_BRANCH"])
        end
        module_function :repo_dir

        def build_all_archives
                build_config() if @config.empty?
                r_dir = repo_dir()
                @all_archives = Dir.glob(r_dir + "/*/*.tar.gz")
        end
        module_function :build_all_archives

        # compiling a lambda once, for future reuse
        L_basename = lambda {|pkg| File.basename(pkg, '.tar.gz') }
        L_include = lambda {|list, pkg|
                re_pkg = Regexp.compile(Regexp.escape(pkg), true)
                list.each {|item|
                        if re_pkg.match(item)
                                return item
                        end
                }
                return false
        }

        # returns a cleaned +String+ of the pkg name
        def file_basename(archive)
                return L_basename.call(archive)
        end
        module_function :file_basename

        def have_match(list, pkg)
                return L_include.call(list,pkg)
        end
        module_function :have_match

        def guess_deps(all_archives,archive)
                deps = []
                s_name = file_basename(archive)
                r = read_archive_file(archive, s_name + "/README")
                r.gsub(/[(\[\]*):,\.]/, " ").split(/[\s\n]/).each {|word|
                        next if word == s_name
                        next if word == ""
                        if item = have_match(all_archives, word)
                                next if item == s_name
                                deps << item
                        end
                }
                return deps
        end
        module_function :guess_deps

        # Returns an +Array+ of the names of all the archives
        def list_basenames()
                build_all_archives.map {|arc| file_basename(arc) }
        end
        module_function :list_basenames

        def read_archive_file(archive, file)
                begin
                        i = IO.popen("tar Oxf #{archive} #{file}")
                        buf = i.read
                        i.close
                        return buf
                rescue
                        raise StandardError.new("ERROR: #{file} failed to extract\n")
                end
        end
        module_function :read_archive_file

        def get_archive_slackdesc(archive)
                s_name = file_basename(archive)
                return read_archive_file(archive, "#{s_name}/slack-desc").split("\n")
        end
        module_function :get_archive_slackdesc

        def get_archive_info(archive)
                s_name = file_basename(archive)
                return parse_info(read_archive_file(archive, "#{s_name}/#{s_name}.info"))
        end
        module_function :get_archive_info

        def parse_info(info)
                unless info.is_a?(Array)
                        info = info.gsub(/\\\n/," ").split("\n")
                end
                h = {}
                info.each {|f|
                        k,v = f.split("=")
                        next if f.nil? or f.empty?
                        begin
                                h[k] = v[1..-2]
                        rescue
                                nil
                        end
                }
                info = s_name = nil
                return h
        end
        module_function :parse_info

        class Build
                attr_accessor :prgnam, :info, :dir, :arch

                def initialize(dir = ".")
                        @dir = File.expand_path(dir)

                        if ENV["ARCH"]
                                @arch = ENV["ARCH"]
                        else
                                a = `uname -m`.chomp
                                case a
                                when a =~ /i?86/
                                        @arch = "i486"
                                when a =~ /arm*/
                                        @arch = "arm"
                                else
                                        @arch = a
                                end
                        end

                        # if there i a single *.info file present, along with a
                        # slack-desc, then assume it is a project's working dir
                        p_info = Dir.glob(@dir + "/*.info")
                        if p_info.count == 1 and File.exist?(@dir + "/slack-desc")
                                @info = SBo.parse_info(File.read(p_info.first))
                                if @info.has_key?("PRGNAM")
                                        @prgnam = @info["PRGNAM"]
                                end
                        end
                end

                def dir=(dir)
                        @dir = File.expand_path(dir)
                end

                def get_source

                        report = {}

                        return report if @info.nil? or @info.empty?

                        if @arch == "x86_64" and not(@info["DOWNLOAD_x86_64"].empty?)
                                urls = @info["DOWNLOAD_x86_64"].split
                                md5s = @info["MD5SUM_x86_64"].split
                        else
                                urls = @info["DOWNLOAD"].split
                                md5s = @info["MD5SUM"].split
                        end

                        for url in urls

                                # this could be a stronger file name check, i'm sure
                                f_name = url.split("/").last
                                report[f_name] = {:url => url }

                                unless File.exist?(f_name)
                                        system("wget --no-check-certificate #{url.inspect}")
                                end

                                real_md5 = Digest::MD5.file(f_name).hexdigest
                                check_md5 = md5s[urls.index(url)]

                                report[f_name][:md5] = real_md5

                                report[f_name][:md5_pass] = (real_md5 == check_md5)
                        end

                        return report
                end

                def write_info
                        # construct the *.info, from @info
                end

                def diff
                        begin
                                cwd = Dir.pwd
                                tmp_dir = "/tmp/tmp" + rand(99999).to_s(36)
                                FileUtils.mkdir_p(tmp_dir)
                                FileUtils.cd(tmp_dir)

                                files = Dir.glob(SBo.repo_dir() + "/*/#{@prgnam}.tar.gz")
                                files = files.map {|f| f if @prgnam == File.basename(f, ".tar.gz") }.uniq
                                return false if files.count != 1

                                system("tar xzf #{files.first}")
                                
                                system("diff -ur #{cwd} #{@prgnam}")


                        ensure
                                FileUtils.cd(cwd)
                                FileUtils.rm_rf(tmp_dir)
                        end
                end

                def build(env = "")
                        cmd = "#{env} sudo sh #{@prgnam}.SlackBuild"
                        puts cmd
                        return system(cmd)
                end

                def bundle(outputdir = ENV["HOME"])
                        if @arch == "x86_64" and not(@info["DOWNLOAD_x86_64"].empty?)
                                urls = @info["DOWNLOAD_x86_64"].split
                        else
                                urls = @info["DOWNLOAD"].split
                        end

                        # remove the downloaded files
                        for url in urls
                                f_name = url.split("/").last
                                FileUtils.rm(f_name) if File.exist?(f_name)
                        end

                        # remove tempfiles
                        FileUtils.rm(Dir.glob(@dir + "/*~"))

                        cwd = Dir.pwd
                        FileUtils.cd("..")

                        cmd = "tar zcvf #{outputdir}/#{@prgnam}.tar.gz #{@prgnam}/"
                        puts("\n" + cmd)
                        system(cmd)

                        FileUtils.cd(cwd)
                end

                def self::show_info(info)
                        show_info(info)
                end
                def show_info(info = @info)
                        return "" if info.nil? or info.empty?

                        str = ""
                        len = info.keys.map {|k| k.length }.sort.last
                        info.each {|k,v|
                                str += sprintf("%#{len}.#{len}s=%s\n", k, v.inspect)
                        }
                        return str
                end

                def self::validate_info(info)
                        validate_info(info)
                end
                def validate_info(info = @info)
                        report = {}
                        return report if info.nil? or info.empty?

                        # First check that all the fields are present
                        vars = %w{PRGNAM VERSION HOMEPAGE DOWNLOAD MD5SUM DOWNLOAD_x86_64 MD5SUM_x86_64 MAINTAINER EMAIL APPROVED}
                        vars.each {|var|
                                if info.keys.include?(var)
                                        report[var] = true
                                else
                                        report[var] = false
                                end
                        }

                        # Next check if fields are populated, or not
                        info.each {|k,v|
                                # these should have a value
                                if %w{PRGNAM VERSION HOMEPAGE DOWNLOAD MAINTAINER EMAIL}.include?(k)
                                        if v.empty?
                                                report[k] = false
                                        else
                                                report[k] = true
                                        end
                                end
                                # these should *not* have a value
                                if %w{APPROVED}.include?(k)
                                        if v.empty?
                                                report[k] = true
                                        else
                                                report[k] = false
                                        end
                                end

                        }
                        return report
                end

                def inspect
                        "#<%s::0x%x prgnam=%s dir=%s info=%s >" % [self.class.name, self.object_id, @prgnam.inspect, @dir.inspect, @info.inspect]
                end

        end
end # module SBo


if __FILE__ == $PROGRAM_NAME

        options = {}
        opts = OptionParser.new {|opt|
                opt.on("-s","show sbopkg config") {|o|
                        options[:config] = o
                }
                opt.on("-l","list basename packages") {|o|
                        options[:list] = o
                }
                opt.on("-d","attempt to guess dependencies") {|o|
                        options[:guess_deps] = o
                }
                opt.on("-u","unified diff from SBo") {|o|
                        options[:diff] = o
                }
                opt.on("-g","get the source for the current directory") {|o|
                        options[:get_source] = o
                }
                opt.on("-b","build the current directory") {|o|
                        options[:build] = o
                }
                opt.on("-V","validate the *.info in the current directory") {|o|
                        options[:validate_info] = o
                }
                opt.on("-B","bundle the current directory") {|o|
                        options[:bundle] = o
                }
        }.parse!

        if (options[:config])
                SBo.parse_config().each {|k,v|
                        printf("%15.15s: %s\n", k, v)
                }
                exit
        end


        if (options[:list])
                puts SBo.list_basenames().sort
                exit
        end

        if (options[:guess_deps])
                names = SBo.list_basenames()
                SBo.build_all_archives.each {|pkg|
                        #h = SBo.get_archive_info(pkg)
                        #printf("%s-%s\n", h["PRGNAM"], h["VERSION"])
                        #h = nil
                        deps = SBo.guess_deps(names, pkg)

                        puts "#{pkg}: deps: #{deps.count}"
                        p deps
                        puts 
                }
        end

        if (options[:get_source])
                sb = SBo::Build.new
                printf("%s\n", sb.show_info)

                results = sb.get_source()
                col_len = results.keys.map {|k| k.length }.sort.last
                results.each {|file, res|
                        printf("%s :: %#{col_len}.#{col_len}s with MD5 of %s\n",
                                        res[:md5_pass] ? "PASSED" : "FAILED",
                                        file,
                                        res[:md5])
                }
        end

        if (options[:build])
                ret = true
                sb = SBo::Build.new
                printf("%s\n", sb.show_info)

                # sillyness to preserve env
                env = ENV.to_a.map {|k,v| "#{k}=#{v.inspect}" }.join(" ")
                sb.build(env)
        end

        if (options[:diff])
                sb = SBo::Build.new
                sb.diff
        end
        if (options[:validate_info])
                sb = SBo::Build.new
                printf("%s\n", sb.show_info)
                report = sb.validate_info()
                if report.values.include?(false)
                        printf("WARNING: the %s.info file is not presently valid\n", sb.prgnam)
                        report.each {|k,v|
                                printf("%s needs attention\n", k) if v == false
                        }
                else
                        printf("INFO: the %s.info file valid\n", sb.prgnam)
                end
        end
        if (options[:bundle])
                sb = SBo::Build.new
                printf("%s\n", sb.show_info)
                report = sb.validate_info()
                if report.values.include?(false)
                        printf("WARNING: the %s.info file is not presently valid\n", sb.prgnam)
                        report.each {|k,v|
                                printf("%s needs attention\n", k) if v == false
                        }
                else
                        printf("INFO: the %s.info file valid\n", sb.prgnam)
                        sb.bundle
                end
        end
end


