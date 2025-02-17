# -*- encoding: utf-8 -*-
# stub: filewatch 0.6.7 ruby lib lib

Gem::Specification.new do |s|
  s.name = "filewatch"
  s.version = "0.6.7"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib", "lib"]
  s.authors = ["Jordan Sissel", "Pete Fritchman"]
  s.date = "2015-12-02"
  s.description = "Watch files and directories in ruby. Also supports tailing and glob file patterns."
  s.email = ["jls@semicomplete.com", "petef@databits.net"]
  s.executables = ["globtail"]
  s.files = ["bin/globtail"]
  s.homepage = "https://github.com/jordansissel/ruby-filewatch"
  s.rubygems_version = "2.4.8"
  s.summary = "filewatch - file watching for ruby"

  s.installed_by_version = "2.4.8" if s.respond_to? :installed_by_version

  if s.respond_to? :specification_version then
    s.specification_version = 4

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_development_dependency(%q<stud>, [">= 0"])
    else
      s.add_dependency(%q<stud>, [">= 0"])
    end
  else
    s.add_dependency(%q<stud>, [">= 0"])
  end
end
