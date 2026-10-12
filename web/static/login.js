(function () {
  "use strict";

  var form = document.getElementById("form");
  var username = document.getElementById("username");
  var password = document.getElementById("password");
  var submitBtn = document.getElementById("submitBtn");
  var error = document.getElementById("error");

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    error.textContent = "";
    submitBtn.disabled = true;
    submitBtn.textContent = "登录中…";

    fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: username.value, password: password.value })
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (!res.ok) {
          throw new Error(data.error || ("HTTP " + res.status));
        }
        return data;
      });
    }).then(function () {
      window.location.href = "/";
    }).catch(function (err) {
      error.textContent = err.message;
      submitBtn.disabled = false;
      submitBtn.textContent = "登录";
      password.value = "";
      password.focus();
    });
  });

  username.focus();
})();
