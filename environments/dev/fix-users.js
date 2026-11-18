const { PrismaClient } = require("@prisma/client");
const bcrypt = require("bcryptjs");

const prisma = new PrismaClient();

const users = [
  ["admin@nexops.com", "Admin@NexOps2026", "System Admin", "admin"],
  ["hr@nexops.com", "HrPortal@2026", "HR Manager", "hr"],
  ["manager@nexops.com", "Manager@2026", "Team Manager", "manager"],
  ["employee@nexops.com", "Employee@2026", "Demo Employee", "employee"]
];

async function main() {
  for (const [email, password, fullName, role] of users) {
    const hash = await bcrypt.hash(password, 12);

    await prisma.user.upsert({
      where: { email },
      update: {
        password: hash,
        fullName,
        role,
        isActive: true
      },
      create: {
        email,
        password: hash,
        fullName,
        role,
        isActive: true
      }
    });

    console.log("ENSURED:", email);
  }

  await prisma.$disconnect();
}

main().catch(async (error) => {
  console.error(error);
  await prisma.$disconnect();
  process.exit(1);
});
