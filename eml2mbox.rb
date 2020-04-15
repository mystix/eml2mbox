#!/usr/bin/ruby
# encoding: utf-8
#============================================================================================#
# Converts a bunch of eml files into one mbox file.                                          #
#                                                                                            #
# Usage: [ruby] eml2mbx.rb [-a] [-c] [-h] [-l] [-m] [-s] [-yz] [emlpath [trgtmbx]]           #
#         Switches:                                                                          #
#            -a assume all files are emails - ignore extensions                              #
#            -c Remove CRs (^M) appearing at end of lines (Unix)                             #
#            -f Act on a single .eml file, rather than an .eml dir                           #
#            -l Remove LFs appearing at beginning of lines (old Mac) - not tested            #
#            -h Show help and exit                                                           #
#            -m Handle multiline From: headers (RFC822 phrase + routed_addr)                 #
#            -s Don't use standard mbox postmark formatting (for From_ line)                 #
#               This will force the use of original From and Date found in mail headers.     #
#               Not recommended, unless you really have problems importing emls.             #
#           -yz Use this to force the order of the year and timezone in date in the From_    #
#               line from the default [timezone][year] to [year][timezone].                  #
#         emlpath - Path of dir with eml files. Defaults to the current dir if not specified #
#         trgtmbx - Name of the target mbox file. Defaults to "archive.mbox" in 'emlpath'    #
#                                                                                            #
#============================================================================================#
# Licence:                                                                                   #
#                                                                                            #
# This script is free software; you can redistribute it and/or modify it under the terms of  #
# the GNU Lesser General Public License as published by the Free Software Foundation;        # 
# either version 2.1 of the License, or (at your option) any later version.                  #
#                                                                                            #
# You should have received a copy of the GNU Lesser General Public License along with this   #
# script; if not, please visit http://www.gnu.org/copyleft/gpl.html for more information.    #
#============================================================================================#

require "date"

#=======================================================#
# Class that encapsulates the processing file in memory #
#=======================================================#

class FileInMemory
    
    ZoneOffset = {
        # Standard zones by RFC 2822
        'UTC' => '0000', 
        'UT' => '0000', 'GMT' => '0000',
        'EST' => '-0500', 'EDT' => '-0400',
        'CST' => '-0600', 'CDT' => '-0500',
        'MST' => '-0700', 'MDT' => '-0600',
        'PST' => '-0800', 'PDT' => '-0700',
    }   
    
    def initialize()
        @lines = Array.new
        @counter = 1          # keep the 0 position for the From_ line
        @from = nil           # from part of the From_ line
        @prefrom = nil        # buffer for multiline From:
        @date = nil           # date part of the From_ line
    end

    def addLine(line)
        line = line.force_encoding("ISO-8859-1").encode("utf-8", replace: nil)

        # If the line is a 'false' From line, add a '>' to its beginning
        line = line.sub(/From/, '>From') if line =~ /^From/ and @from!=nil

        # If previous line was a two-liner From header without address concatenate both
        if @prefrom != nil
            line = @prefrom + " " + line
            @prefrom = nil
        end
        
        # If the line is the first valid From line, save it (without the line break)
        if line =~ /^From:\s.*/ and @from==nil
            if line =~ /.*@/
                @from = line.sub(/From:/,'From')
                @from = @from.chop    # Remove line break(s)
                @from = standardizeFrom(@from) unless $switches["noStandardFromLine"]
            elsif $switches["multilineFrom"]
                @prefrom = line.chop
            end
        end

        # Get the date
        if $switches["noStandardFromLine"]
            # Don't parse the content of the Date header
            @date = line.sub(/Date:\s/,'') if line =~ /^Date:\s/ and @date==nil
        else
            if line =~ /^Date:\s/ and @date==nil
                # Parse content of the Date header and convert to the mbox standard for the From_ line
                @date = line.sub(/Date:\s/,'')
                year, month, day, hour, minute, second, timezone, wday = DateTime._parse(@date, false).values_at(:year, :mon, :mday, :hour, :min, :sec, :zone, :wday)
                # Need to convert the timezone from a string to a 4 digit offset
                unless timezone =~ /[+|-]\d*/
                    timezone=ZoneOffset[timezone]
                end
                begin
                   time = Time.gm(year,month,day,hour,minute,second)
                   @date = formMboxDate(time,timezone)
                rescue
                   @date = nil
                   $errors = true
                   print "[skipping bad date]"
                end
            end
        end

        # Now add the line to the array
        line = fixLineEndings(line)
        @lines[@counter]=line
        @counter+=1
    end

    # Forms the first line (from + date) and returns all the lines
    # Returns all the lines in the file
    def getProcessedLines()
        if @from != nil
            # Add from and date to the first line
            if @date==nil
                $errors = true
                print "[replacing bad date with now]"
                @date=formMboxDate(Time.now,nil)
            end
            @lines[0] = @from + " " + @date 
            
            @lines[0] = fixLineEndings(@lines[0])
            @lines[@counter] = ""
            return @lines
        end
        # else don't return anything
    end

    # Fixes CR/LFs
    def fixLineEndings(line)
        line = removeCR(line) if $switches["removeCRs"];
        line = removeLF(line) if $switches["removeLFs"];
        return line
    end

    # emls usually have CR+LF (DOS) line endings, Unix uses LF as a line break,
    # so there's a hanging CR at the end of the line when viewed on Unix.
    # This method will remove the next to the last character from a line
    def removeCR(line)
        line = line[0..-3]+line[-1..-1] if line[-2]==0xD
        return line
    end

    # Similar to the above. This one is for Macs that use CR as a line break.
    # So, remove the last char
    def removeLF(line)
        line = line[0..-2] if line[-1]==0xA
        return line
    end

end

#================#
# Helper methods #
#================#

# Converts: 'From "some one <aa@aa.aa>" <aa@aa.aa>' -> 'From aa@aa.aa'
def standardizeFrom(fromLine)
    # Get indexes of last "<" and ">" in line
    openIndex = fromLine.rindex('<')
    closeIndex = fromLine.rindex('>')
    if openIndex!=nil and closeIndex!=nil
        fromLine = fromLine[0..4]+fromLine[openIndex+1..closeIndex-1]
    end
    # else leave as it is - it is either already well formed or is invalid
    return fromLine
end

# Returns a mbox postmark formatted date.
# If timezone is unknown, it is skipped.
# mbox date format used is described here:
# http://www.broobles.com/eml2mbox/mbox.html
def formMboxDate(time,timezone)
    if timezone==nil
        return time.strftime("%a %b %d %H:%M:%S %Y")
    else
        if $switches["zoneYearOrder"]
            return time.strftime("%a %b %d %H:%M:%S #{timezone.to_s} %Y")
        else 
            return time.strftime("%a %b %d %H:%M:%S %Y #{timezone.to_s}")
        end
    end
end

# Extracts all switches from the command line and returns
# a hashmap with valid switch names as keys and booleans as values
# Moves real params to the start of the ARGV array
def extractSwitches()
    switches = Hash.new(false)  # All switches (values) default to false
    i=0
    while (ARGV[i]=~ /^-/)  # while arguments are switches
        if ARGV[i]=="-a"
            switches["ignoreExt"] = true
            puts "\nWill ignore file extension, assume all files are emails"
        elsif ARGV[i]=="-c"
            switches["removeCRs"] = true
            puts "\nWill fix lines ending with a CR"
        elsif ARGV[i]=="-f"
            switches["singleFile"] = true
            puts "\nWill act on a single .eml file, rather than an .eml dir"
        elsif ARGV[i]=="-h"
            switches["showHelp"] = true
            puts "\nWill show help and exit"
        elsif ARGV[i]=="-l"
            switches["removeLFs"] = true
            puts "\nWill fix lines beginning with a LF"
        elsif ARGV[i]=="-m"
            switches["multilineFrom"] = true
            puts "\nWill handle Outlook phrase + route_addr multiline From_ headers"
        elsif ARGV[i]=="-s"
            switches["noStandardFromLine"] = true
            puts "\nWill use From and Date from mail headers in From_ line"
        elsif ARGV[i]=="-yz"
            switches["zoneYearOrder"] = true
            puts "\nTimezone will be placed before the year in From_ line"
        else
            puts "\nUnknown switch: "+ARGV[i]+". Ignoring."
        end
        i = i+1
    end
    # Move real arguments to the start of the array
    ARGV[0] = ARGV[i]
    ARGV[1] = ARGV[i+1]
    return switches
end

# Shows usage instructions
def showHelp()
    puts "# Usage: [ruby] eml2mbx.rb [-a] [-c] [-h] [-l] [-m] [-s] [-yz] [emlpath [trgtmbx]]           #
#         Switches:                                                                          #
#            -a assume all files are emails - ignore extensions                              #
#            -c Remove CRs (^M) appearing at end of lines (Unix)                             #
#            -l Remove LFs appearing at beginning of lines (old Mac) - not tested            #
#            -h Show help and exit                                                           #
#            -m Handle multiline From: headers (RFC822 phrase + routed_addr)                 #
#            -s Don't use standard mbox postmark formatting (for From_ line)                 #
#               This will force the use of original From and Date found in mail headers.     #
#               Not recommended, unless you really have problems importing emls.             #
#           -yz Use this to force the order of the year and timezone in date in the From_    #
#               line from the default [timezone][year] to [year][timezone].                  #
#         emlpath - Path of dir with eml files. Defaults to the current dir if not specified #
#         trgtmbx - Name of the target mbox file. Defaults to 'archive.mbox' in 'emlpath'    #
#                                                                                            #
#============================================================================================#"
end

#===============#
#     Main      #
#===============#

$switches = extractSwitches()
if $switches["showHelp"]
    showHelp()
    abort("")
end
$stdout.sync = true

# Extract specified directory with emls and the target archive (if any)
emlDir = __dir__     # default if not specified
if ARGV[0]
  if $switches["singleFile"]
    emlDir = File.dirname(ARGV[0])
    emlFile = File.basename(ARGV[0])
  else
    emlDir = ARGV[0]
  end
end
mboxArchive = ARGV[1] || File.join(emlDir, "archive.mbox") # default if not specified

# Show specified settings
puts "\nSpecified dir : #{emlDir}"
puts "Specified file: #{mboxArchive}\n"

# Check if destination file exists. If yes allow user to select an option.
canceled = false
if FileTest.exist?(mboxArchive)
    print "\nFile [#{mboxArchive}] exists! Please select: [A]ppend  [O]verwrite  [C]ancel (default) "
    sel = STDIN.gets.chomp
    if sel == 'A' or sel == 'a'
        aFile = File.new(mboxArchive, "a");
    elsif sel == 'O' or sel == 'o'
        aFile = File.new(mboxArchive, "w");
    else
        canceled = true
    end
else
    # File doesn't exist, open for writing
    aFile = File.new(mboxArchive, "w");
end

# Check that the dir exists
if FileTest.directory?(emlDir)
    Dir.chdir(emlDir)
else
    puts "\n[#{emlDir}] is not a directory (might not exist). Please specify a valid dir"
    exit(0)
end

if not canceled
    puts
    if $switches["singleFile"]
      files = [emlFile]
      if not FileTest.exist?(emlFile)
         puts "That eml file does not exist. mbox file not created."
         aFile.close
         File.delete(mboxArchive)
         exit(0)
      end
    else
      if $switches["ignoreExt"]
        globtext = "*"
      else
        globtext = "*.{eml,mai}"
      end
      files = Dir.glob(globtext, File::FNM_CASEFOLD)
      if files.size == 0
        puts "No *.eml files in this directory. mbox file not created."
        aFile.close
        File.delete(mboxArchive)
        exit(0)
      end
    end
    # For each .eml file in the specified directory do the following
    puts "About to process #{files.size} mail files"
    filenum = 0
    errors = 0
    files.each() do |x|
        $errors = false
        filenum += 1
        filenumtxt = filenum.to_s.rjust("#{files.size}".length)
        print "#{filenumtxt}/#{files.size}: #{x}  "
        thisFile = FileInMemory.new()
        File.open(x).each  {|item| thisFile.addLine(item) }
        lines = thisFile.getProcessedLines
        if lines == nil
            $errors = true
            print "[skipping mail without regular From: line]"
        else
            lines.each {|line| aFile.puts line}
        end
        if $errors
          print "\n"
          errors += 1
        else
          print "\r"
        end
    end
    aFile.close
    puts "There were #{errors} files with errors.                                        "
end
