// TechStock — config.js
// PREENCHA apiUrl com o DNS do seu ALB antes de fazer deploy
// Formato: 'http://SEU-ALB.us-east-1.elb.amazonaws.com'  ← sem barra final, sem /grafana

window.TECHSTOCK_CONFIG = {
  // Substitua pelo DNS do seu Application Load Balancer:
  apiUrl: 'http://techstock-alb-2074710369.us-west-2.elb.amazonaws.com'   // Ex: 'http://techstock-lb-105375070.us-east-1.elb.amazonaws.com'
};
