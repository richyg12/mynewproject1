#!/usr/bin/perl -w
use strict;
use IO::Handle;
use File::Basename;
use POSIX qw(strftime);

# ##############################################################################
# Name:		webMethodsHk.pl
#
# Ver:		1.2 dhsd oiashdpoisad 
#
# Desc:		File housekeeping script. Deletes and/or Archives files as
#		specified in webMethodsHk.conf
#
# Usage:	path/webMethodsHk.pl [pathToLogFile]
#		if pathToLogFile not specified, logs in DEFAULT_LOG_PATH
#
# Notes:	The log files are datestamped YYYYMM so a new one is started every
# 		month... you may want to inlcude a config line for them!
#
#		Each line in webMethodsHk.conf has three possible formats:
#
#    		fileDir, fileMask, [daysToDelete, daysToArchive, archiveDir]
#    		x:excludePath [, excludePath]
#    		b:pathToBackup, pathToTarStore
#
# 		where:
#    		fileDir - location below which to archive/delete
#    		fileMask - files to be archived/deleted
#    		daysToDelete - (optional) days after which files are deleted
#    		daysToArchive - (optional) days after which files are archived
#    		archiveDir - (optional) where to place archive files
#    		excludePath - full path of file to exclude from the process
#		pathToBackup - full path to file (or directory) to backup (tar)
#		pathToStoreTar - full path to directory in which to place the backup tar
#
# 		- Blank and comment (#) lines are ignored.
# 		- Files will be deleted and/or archived within "fileDir" and ALL
#   		subdirectories thereunder.
#		- If "fileDir" does not conform to ALLOW_PATTERN the line will not be processed
#		- If "fileMask" is not restrictive enough (i.e. *) the line will not be processed.
# 		- Be aware that during the delete operation, subdirectories will be
#   		removed if they too are older than "daysToDelete".
# 		- If "archiveDir" is not specified then a directory called "_archive"
#   		located under "fileDir" will be used.
# 		- "daysToDelete" operates on "fileDir/.../fileMask" if "daysToArchive" is
#   		not specified, or on "fileDir/archiveDir/.../fileMask*.gz" if it is.
# 		- The default action if no optional parameters are specified is to
#   		delete files "fileDir/.../fileMask" after DEFAULT_DEL_DAYS days.
# 		- Files are excluded by "touch"ing to update the modify timestamp.
#		- Backup files will be placed in a tar archive stored in pathToStoreTar named
#		basename(pathToBackup)_$zipStamp.tar
#
# Updates:	MGT 27/07/2011
#		- Added bad return code if any error encountered during the run
#		- Beefed up error handling
#		- Removed logging of processed file names (clogs the log as there are too many!)
#		- Add a backup option (B: config line)
# ##############################################################################

use constant TRUE => 1;
use constant FALSE => 0;

use constant DEFAULT_LOG_PATH => '/tmp';
use constant DEFAULT_DEL_DAYS => 28;
use constant ALLOW_PATTERN => qr(^/home/richyg/mynewproject|^/app/opt/sag/9.12/MWS/profiles/MWS_TSTMWS912a/configBackup);

my $zipStamp = strftime('%Y%m%d',localtime);	# Daily timestamp for archived files
my $logStamp = strftime('%Y%m',localtime);	# Monthly timestamp for log file

my ($prog, $here) = fileparse($0, qr/\.[^.]*/);	# This program minus any extension and where we're running from
my $configFile = "$here/$prog.conf";		# Full path to the configuration file
my ($logPath, $logFile);			# Log details

my ($fileDir, $fileMask, $delDays, $arcDays, $arcDir);	# Config variables

my @excludeList;				# array of filepaths to exclude i.e. "touch" to redate
my $delDir;					# Directory on which to perform the delete function
my $delMask;					# File mask on which to perform the delete function
my $commandRc;					# Return code from OS command
my $commandOut;					# Capture command output for error info
my @fileList;					# List of affected files
my ($sourcePath, $backupDir);			# Source and target for backup operation
my $backupFile;					# Fully qualified name of the backup tar file
my $rc = 0;					# Stored return code for exit status
my $arcDirBase;					# Basename of the archive dir to exclude it from the archive

# ##############################################################################
# Log a line in the program error log
# ##############################################################################
sub report {
   my ($type, $msg) = @_;
   print LOG scalar localtime, " [$type] $msg\n";
   return TRUE;
}

# ##############################################################################
# Handle an error
# ##############################################################################
sub handleIt {
   my ($msg) = @_;
   my $reason = ($!) ? $! : 'n/a';
   report ("E", "Error trapped: $msg, Reason: $reason");
   return TRUE;
}

# ##############################################################################
# Return string of file basenames from an array of full paths (can also be used
# to 'sanitise' error output from find...)
# ##############################################################################
sub formatFindOutput {
   my @fileList = @_;
   my @baseFileList;
   if (@fileList > 0) {
      foreach my $file (@fileList) {
         push @baseFileList, basename($file);
      }
   }
   return ("@baseFileList");
}


# ##############################################################################
# main:: Code begins...
# ##############################################################################
# If an argument is passed, assume it is the log directory. If it doesn't exist,
# default to the default dir or the scripts running directory if that doesn't exist
$logPath = pop @ARGV if (@ARGV);
$logPath = DEFAULT_LOG_PATH if ! ($logPath && -d $logPath);
$logPath = $here if ! -d $logPath;

# Assign and open the log file setting autoflush for immediate writes
$logFile = "$logPath/$prog" . "_$logStamp.log";
open (LOG, ">>$logFile") ||die "Error opening log $logFile: $!";
LOG->autoflush(1);

# ##############################################################################
# First open of configuration file for backup files
unless (open (CONF, $configFile)) {
   handleIt "failed to open configuration file $configFile for backup processing";
   exit 1;
}

# Loop through the conf file
while (<CONF>) {
   chomp;

   # Ignore blank and comment lines and strip all spaces
   next if /^\s*#|^\s*$/;
   s/\s//g;

   # Ignore non "backup" lines and log start
   next if !/^[bB]:/;
   report ('I', "Processing config line \"$_\"");

   # Log badly formatted lines
   if (!/^[^,]+,[^,]+$/) {
      report ('E', "Skipping bad backup line: \"$_\"");
      $rc = 4;
      next;
   }

   # Strip the b: indicator and retrieve working variables
   s/^[bB]://;
   ($sourcePath, $backupDir) = split(/,/);

   # Create backup directory if it's not there
   if (! -d $backupDir) {
      if (mkdir $backupDir) {
         report ('I', "Created backup directory $backupDir");
      }
      else {
         handleIt ("Failed to create backup directory $backupDir");
         $rc = 4;
         next;
      }
   }

   # Backup the file
   $backupFile = "$backupDir/" . basename($sourcePath) . "_$zipStamp.tar";
   chomp ($commandOut = qx(tar cvf $backupFile $sourcePath 2>&1 1>/dev/null));
   $commandRc = $? >> 8;
   if ($commandRc > 0) {
      report ('E', "Error ($commandRc) from OS command - $commandOut");
      $rc = 4;
   }
   else {
      report ('I', "Successfully backed up $sourcePath to $backupFile");
   }
}

# ##############################################################################
# Second open of configuration file for exclude phase
unless (open (CONF, $configFile)) {
   handleIt "failed to open configuration file $configFile for exclude processing";
   exit 1;
}

# Loop through the conf file
while (<CONF>) {
   chomp;

   # Ignore blank and comment lines and strip all spaces
   next if /^\s*#|^\s*$/;
   s/\s//g;

   # Ignore non "exclude" lines and log start
   next if !/^[xX]:/;
   report ('I', "Processing config line \"$_\"");

   # Log badly formatted lines
   if (!/^[^,]+(,[^,]+)*$/) {
      report ('E', "Skipping bad exclude line: \"$_\"");
      $rc = 4;
      next;
   }

   # Strip the x: indicator
   s/^[xX]://;

   # Append to the exclude list
   @excludeList = (@excludeList, split(/,/));
}

# If there are files to exclude, loop through exclude list touching each file
# to reset modify date effectively excluding it from the archive/delete phase
if (@excludeList) {
   report ('I', "The following files will be excluded: @excludeList");
   foreach my $file (@excludeList) {
      if (-e $file) {
         chomp ($commandOut = qx(touch $file 2>&1 1>/dev/null));
         $commandRc = $? >> 8;
         if ($commandRc > 0) {
            report ('E', "File $file will not be excluded! Error ($commandRc) from OS command - $commandOut");
            $rc = 4;
         }
      }
      else {
         report ('W', "Exclude file $file not found");
      }
   }
}

# ##############################################################################
# Last open of configuration file for archive/delete phase
unless (open (CONF, $configFile)) {
   handleIt "failed to open configuration file $configFile for archive/delete processing";
   exit 1;
}

# Loop through the conf file
while (<CONF>) {
   chomp;

   # Ignore blank, comment "exclude" and "backup" lines, strip all spaces and log start
   next if /^\s*#|^\s*$|^\s*[bBxX]:/;
   s/\s//g;
   report ('I', "Processing config line \"$_\"");

   # Log badly formatted lines
   if (!/^[^,]+,[^,]+(,\d+)?(,\d+)?(,[^,]+)?$/) {
      report ('E', "Skipping bad config: badly formatted line");
      $rc = 4;
      next;
   }

   # Retrieve the settings
   ($fileDir, $fileMask, $delDays, $arcDays, $arcDir) = split(/,/);

   # Safety measure! Skip dangerous directories
   if ($fileDir !~ ALLOW_PATTERN) {
      report ('E', "Skipping dangerous config: trying to archive outside of allowed directories");
      $rc = 4;
      next;
   }

   # Safety measure! Don't allow unspecific mask
   if ($fileMask =~ /^\**\w{0,2}\**$/) {
      report ('E', "Skipping dangerous config: mask must be more specific");
      $rc = 4;
      next;
   }

   # Validate the file directory and update timestamp to exclude the dir itself from processing
   if (! -d $fileDir) {
      report ('E', "Skipping bad config: $fileDir not found");
      $rc = 4;
      next
   }
   else {
      chomp ($commandOut = qx(touch $fileDir 2>&1 1>/dev/null));
      $commandRc = $? >> 8;
      if ($commandRc > 0) {
         report ('E', "Skipping as we can't timestamp the directory! Error ($commandRc) from OS command - $commandOut");
         $rc = 4;
         next;
      }
   }

   # Default delDays if required and validate timings
   $delDays = DEFAULT_DEL_DAYS if ! $delDays;
   if ($arcDays && $arcDays > $delDays) {
      report ('E', "Skipping bad config: files will be deleted before archiving");
      $rc = 4;
      next
   }

   # Archive only required if $arcDays set
   if ($arcDays) {

      # Default the archive directory if not set and create it if it's not there
      $arcDir = $fileDir . '/_archive' if ! $arcDir;
      $arcDirBase = basename($arcDir);
      if (! -d $arcDir) {
         if (mkdir $arcDir) {
            report ('I', "Created archive directory $arcDir");
         }
         else {
            handleIt ("Failed to create archive directory $arcDir");
            $rc = 4;
            next;
         }
      }

      # Move files to be archived to the archive dir. NB: prune the actual arcDir to prevent double counting before zipping!
      chomp (@fileList = qx(find $fileDir -name $arcDirBase -prune -o -type f -name '$fileMask' -mtime +$arcDays -print -exec mv {} $arcDir \\;));
      $commandRc = $? >> 8;
      if ($commandRc > 0) {
         report ('E', "Error ($commandRc) processing find command");
         $rc = 4;
         next;
      }
      else {
         chomp ($commandOut = qx(find $arcDir -type f ! -name *.gz -exec gzip -S _$zipStamp.gz {} \\; 2>&1 1>/dev/null));
         $commandRc = $? >> 8;
         if ($commandRc > 0) {
            report ('E', "Zip operation failed, " . scalar @fileList . " files have been moved but not zipped! Error ($commandRc) from OS command - $commandOut");
            $rc = 4;
            next;
         }
         else {
            report ('I', scalar @fileList . " files archived");
         }
      }
   }

   # Set the appropriate mask and directory on which to perform the delete.
   if ($arcDays) {
      $delDir = $arcDir;
      $delMask = "$fileMask*.gz";
   }
   else {
      $delDir = $fileDir;
      $delMask = $fileMask;
   }

   # Perform the delete
   chomp (@fileList = qx(find $delDir -name '$delMask' -mtime +$delDays -print -exec rm -rf {} \\;));
   $commandRc = $? >> 8;
   if ($commandRc > 0) {
      report ('E', "Error ($commandRc) in processing find command");
      $rc = 4;
   }
   else {
      report ('I', scalar @fileList . " files deleted");
   }
}

# ##############################################################################
# Exit with return code to indicate any encoutered errors
exit $rc;
