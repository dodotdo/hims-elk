## 2.0.0
 - Plugins were updated to follow the new shutdown semantic, this mainly allows Logstash to instruct input plugins to terminate gracefully, 
   instead of using Thread.raise on the plugins' threads. Ref: https://github.com/elastic/logstash/pull/3895
 - Dependency on logstash-core update to 2.0

# 1.1.0
  - Small refactoring to have functions out of small concepts.
  - Remove the path validation as is broken from the LS side
  - Added basic test to the project
