#!/usr/bin/env ruby

require 'date'
require 'yaml'
require 'json'

git_repo = Dir.pwd

issues = []
hidden = []

curl_auth = ENV['GITHUB_AUTH']

if Dir.glob("licenseCompleter.groovy").empty?
	puts "Usage:    generate-jenkins-changelog.rb <versions>"
	puts ""
	puts "This script needs to be run from a jenkinsci/jenkins clone."
	exit
end

if ARGV.length == 0
	puts "Usage:    generate-jenkins-changelog.rb <versions>"
	puts ""
	puts "Missing argument <versions>"
	puts "To generate the changelog between two commits or tags, specify then with '..' separator:"
	puts "          generate-jenkins-changelog.rb jenkins-2.174..master"
	puts "To generate the changelog for an existing Jenkins release (i.e. from the previous release), specify the version number:"
	puts "          generate-jenkins-changelog.rb 2.174"
	exit
end

if ARGV[0] =~ /\.\./
	# this is a commit range
	new_version = ARGV[0].split('..')[1]
	previous_version = ARGV[0].split('..')[0]
else
	new_version = "jenkins-#{ARGV[0]}"
	splitted = new_version.rpartition('.')
	previous_version = "#{splitted.first}.#{splitted.last.to_i - 1}"
end

puts "Checking range from #{previous_version} to #{new_version}"

# We generally want --first-parent here unless it's the weekly after a security update
# In that case, the merge commit after release will hide anything merged Monday through Wednesday
diff = `git log --pretty=oneline #{previous_version}..#{new_version}`

diff.each_line do |line|
	pr = /#([0-9]{4,5})[) ]/.match(line)
	sha = /^([0-9a-f]{40}) /.match(line)[1]
	full_message = `git log --pretty="%s%n%n%b" #{sha}^..#{sha}`
	issue = /JENKINS-([0-9]{3,5})/.match(full_message.encode("UTF-16be", :invalid=>:replace, :replace=>"?").encode('UTF-8'))
	entry = {}
	if pr != nil
		puts "PR #{pr[1]} found for #{sha}"

		pr_comment_string = `curl --fail --silent -u #{curl_auth} https://api.github.com/repos/jenkinsci/jenkins/pulls/#{pr[1]}`
		pr_commits_string = `curl --fail --silent -u #{curl_auth} https://api.github.com/repos/jenkinsci/jenkins/pulls/#{pr[1]}/commits`
		
		if $?.exitstatus  == 0

			pr_json = JSON.parse(pr_comment_string)
			commits_json = JSON.parse(pr_commits_string)

			labels = pr_json['labels'].map { |l| l["name"] }

			entry['type'] = 'TODO'
			entry['type'] = 'major bug' if labels.include?("major-bug")
			entry['type'] = 'major rfe' if labels.include?("major-rfe")
			entry['type'] = 'bug' if labels.include?("bug")
			entry['type'] = 'rfe' if labels.include?("rfe")

			entry['pull'] = pr[1].to_i
			if issue != nil
				entry['issue'] = issue[1].to_i
			end

			# Resolve Authors
			# TODO(oleg_nenashev): GitHub REST API returns coauthors only as a part of the commit message string
			# "message": "Update core/src/main/java/hudson/model/HealthReport.java\n\nCo-Authored-By: Zbynek Konecny <zbynek1729@gmail.com>"
			# Ther is no REST API AFAICT, user => GitHub ID conversion also requires additional calls
			authors = []
			unresolvedAuthorEmails = []
			unresolvedAuthorNames = Hash.new
			commits_json.each do | commit |
				if commit["author"] # GitHub committer info is attached
					authors << commit["author"]["login"]
				else
					author = commit["commit"]["author"]
					unresolvedAuthorEmails << author["email"]
					unresolvedAuthorNames[author["email"]] = author["name"]
				end
			end
			
			#NOTE(oleg_nenashev): This code will be also needed for parsing co-authors
			unresolvedAuthorEmails.uniq.each do | email | # Try resolving users by asking GitHub
				puts "Resolving GitHub ID for #{unresolvedAuthorNames[email]} (#{email})"
				usersearch_string = `curl --fail --silent -u #{curl_auth} https://api.github.com/search/users?q=#{email}%20in:email`
				usersearch = JSON.parse(usersearch_string)
				if usersearch["items"].length() > 0 
					githubId = usersearch["items"].first["login"]
					authors << githubId
				else
					authors << "TODO: #{unresolvedAuthorNames[email]} (#{email})"
				end
			end

			entry['authors'] = authors.uniq

			proposed_changelog = /### Proposed changelog entries(.*?)(###|\Z)/m.match(pr_json['body'])
			if proposed_changelog != nil
				proposed_changelog = proposed_changelog[1].gsub("\r\n", "\n").gsub(/<!--.*?-->/m, "").strip
			end

			# The presence of '\n' in this string is significant:
			# It's one of the ways the Psych YAML library uses to determine what format to print a string in.
			# This one makes it print a string literal (starting with |), which is easier to edit.
			# https://github.com/ruby/psych/blob/e01839af57df559b26f74e906062be6c692c89c8/lib/psych/visitors/yaml_tree.rb#L299
			if proposed_changelog == nil || proposed_changelog.empty?
				proposed_changelog = "(No proposed changelog)"
			end

			if labels.include?("skip-changelog")
				entry['message'] = "PR title: #{pr_json['title']}"
				hidden << entry
			else
				entry['message'] = "TODO fixup changelog:\nPR title: #{pr_json['title']}\nProposed changelog:\n#{proposed_changelog.strip}"
				issues << entry
			end
		else
			puts "Failed to retrieve PR metadata for <<<<<#{pr[1]}>>>>>"
		end
	else
		puts "No PR found for #{sha}: <<<<<#{full_message.lines.first.strip}>>>>>"
	end
end

issues_by_type = issues.group_by { |issue| issue['type'] }

issues = []
['major rfe', 'major bug', 'rfe', 'bug', 'TODO'].each do |type|
	if issues_by_type.has_key?(type)
		issues << issues_by_type[type]
	end
end
issues = issues.flatten

root = {}
root['version'] = new_version.sub(/jenkins-/, '')
root['date'] = Date.parse(`git log --pretty='%ad' --date=short #{new_version}^..#{new_version}`.strip)
root['changes'] = issues

changelog_yaml = [root].to_yaml
hidden.sort { |a, b| a['pull'] <=> b['pull'] }.each do | entry |
	changelog_yaml += "\n  # pull: #{entry['pull']} (#{entry['message']})"
end
puts changelog_yaml

changelog_path = ENV["CHANGELOG_YAML_PATH"]
if changelog_path != nil
	puts "Writing changelog to #{changelog_path}"
	File.write(changelog_path, changelog_yaml)
end
