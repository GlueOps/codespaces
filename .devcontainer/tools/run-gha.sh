run-gha() {
    #https://stackoverflow.com/questions/6245570/how-do-i-get-the-current-branch-name-in-git
    gh workflow run --ref=$(git rev-parse --abbrev-ref HEAD)
}
